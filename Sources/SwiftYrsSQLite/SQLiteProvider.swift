import Foundation
import SQLite
import SwiftYrs

public enum SQLiteProviderError: Error, Equatable {
    case duplicateProvider(documentName: String)
    case destroyed
    case invalidCompactThreshold(Int)
    case activeProvider(documentName: String)
    case unknownUpdateEncoding(String)
    case unknownUpdateKind(String)
    case emptyUpdateBlob
}

public enum SQLiteUpdateKind: String, Sendable {
    case incremental
    case snapshot
}

public final class SQLiteProviderOptions: Sendable {
    static let `default` = SQLiteProviderOptions(uncheckedAutoCompact: true, compactThreshold: 500)

    public let autoCompact: Bool
    public let compactThreshold: Int

    public init(autoCompact: Bool = true, compactThreshold: Int = 500) throws {
        guard compactThreshold > 0 else {
            throw SQLiteProviderError.invalidCompactThreshold(compactThreshold)
        }
        self.autoCompact = autoCompact
        self.compactThreshold = compactThreshold
    }

    private init(uncheckedAutoCompact autoCompact: Bool, compactThreshold: Int) {
        self.autoCompact = autoCompact
        self.compactThreshold = compactThreshold
    }
}

public final class SQLiteStore: @unchecked Sendable {
    private let connection: Connection
    private let queue = DispatchQueue(label: "SwiftYrsSQLite.SQLiteStore")
    private let registryLock = NSLock()
    private var activeDocumentNames: Set<String> = []

    public init(_ connection: Connection) throws {
        self.connection = connection
    }

    public func createSchemaIfNeeded() throws {
        try sync { connection in
            try SQLiteSchema.create(on: connection)
        }
    }

    public func removeDocument(named documentName: String) throws {
        registryLock.lock()
        defer { registryLock.unlock() }
        if activeDocumentNames.contains(documentName) {
            throw SQLiteProviderError.activeProvider(documentName: documentName)
        }
        try sync { connection in
            try SQLiteSchema.create(on: connection)
            try connection.transaction {
                try connection.run(SQLiteSchema.updates.filter(SQLiteSchema.documentName == documentName).delete())
                try connection.run(SQLiteSchema.metadata.filter(SQLiteSchema.documentName == documentName).delete())
            }
        }
    }

    func registerProvider(documentName: String) throws {
        registryLock.lock()
        defer { registryLock.unlock() }
        guard !activeDocumentNames.contains(documentName) else {
            throw SQLiteProviderError.duplicateProvider(documentName: documentName)
        }
        activeDocumentNames.insert(documentName)
    }

    func unregisterProvider(documentName: String) {
        registryLock.lock()
        activeDocumentNames.remove(documentName)
        registryLock.unlock()
    }

    func sync<T>(_ body: (Connection) throws -> T) throws -> T {
        try queue.sync {
            try body(connection)
        }
    }
}

public final class SQLiteProvider: @unchecked Sendable {
    public let documentName: String
    public let doc: YDoc
    public let store: SQLiteStore
    public let options: SQLiteProviderOptions
    public let synced: AsyncStream<Bool>
    public let errors: AsyncStream<Error>

    public private(set) var isStarted = false

    private let syncedContinuation: AsyncStream<Bool>.Continuation
    private let errorsContinuation: AsyncStream<Error>.Continuation
    private var observation: Observation?
    private var destroyed = false
    private let lifecycleLock = NSLock()

    public convenience init(documentName: String, doc: YDoc, store: SQLiteStore) {
        self.init(documentName: documentName, doc: doc, store: store, options: .default)
    }

    public init(documentName: String, doc: YDoc, store: SQLiteStore, options: SQLiteProviderOptions) {
        self.documentName = documentName
        self.doc = doc
        self.store = store
        self.options = options

        let syncedPair = AsyncStream.makeStream(of: Bool.self)
        self.synced = syncedPair.stream
        self.syncedContinuation = syncedPair.continuation

        let errorsPair = AsyncStream.makeStream(of: Error.self)
        self.errors = errorsPair.stream
        self.errorsContinuation = errorsPair.continuation
    }

    public func start() throws {
        lifecycleLock.lock()
        if destroyed {
            lifecycleLock.unlock()
            throw SQLiteProviderError.destroyed
        }
        if isStarted {
            lifecycleLock.unlock()
            return
        }

        var registered = false
        do {
            try store.registerProvider(documentName: documentName)
            registered = true
            try store.createSchemaIfNeeded()
            let updates = try store.sync { connection in
                try SQLiteSchema.loadUpdates(for: documentName, from: connection)
            }
            for update in updates {
                try doc.apply(update)
            }
            observation = try doc.observeUpdates { [weak self] event in
                guard let self, case let .update(update) = event else {
                    return
                }
                self.persistObservedUpdate(update)
            }

            isStarted = true
            lifecycleLock.unlock()
            syncedContinuation.yield(true)
        } catch {
            observation?.cancel()
            observation = nil
            if registered {
                store.unregisterProvider(documentName: documentName)
            }
            lifecycleLock.unlock()
            throw error
        }
    }

    public func compact() throws {
        let compactedThroughID = try store.sync { connection in
            try SQLiteSchema.maxUpdateID(documentName: documentName, on: connection)
        }
        let snapshot = try doc.encodeStateAsUpdateV1()
        try store.sync { connection in
            try SQLiteSchema.compact(
                documentName: documentName,
                snapshot: snapshot,
                compactedThroughID: compactedThroughID,
                on: connection
            )
        }
    }

    public func setMetadata(_ value: Data, forKey key: String) throws {
        try store.sync { connection in
            try SQLiteSchema.setMetadata(value, forKey: key, documentName: documentName, on: connection)
        }
    }

    public func metadata(forKey key: String) throws -> Data? {
        try store.sync { connection in
            return try SQLiteSchema.metadata(forKey: key, documentName: documentName, from: connection)
        }
    }

    public func removeMetadata(forKey key: String) throws {
        try store.sync { connection in
            try SQLiteSchema.removeMetadata(forKey: key, documentName: documentName, on: connection)
        }
    }

    public func destroy() {
        lifecycleLock.lock()
        guard !destroyed else {
            lifecycleLock.unlock()
            return
        }
        destroyed = true
        let wasStarted = isStarted
        isStarted = false
        lifecycleLock.unlock()

        observation?.cancel()
        observation = nil
        if wasStarted {
            store.unregisterProvider(documentName: documentName)
        }
        syncedContinuation.finish()
        errorsContinuation.finish()
    }

    deinit {
        destroy()
    }

    private func persistObservedUpdate(_ update: YUpdate) {
        do {
            let shouldCompact = try store.sync { connection in
                try SQLiteSchema.append(update, kind: .incremental, documentName: documentName, on: connection)
                let count = try SQLiteSchema.updateCount(documentName: documentName, on: connection)
                return options.autoCompact && count >= options.compactThreshold
            }
            if shouldCompact {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
                    do {
                        try self.compact()
                    } catch {
                        self.errorsContinuation.yield(error)
                    }
                }
            }
        } catch {
            errorsContinuation.yield(error)
        }
    }
}

enum SQLiteSchema {
    static let updates = Table("swiftyrs_sqlite_updates")
    static let metadata = Table("swiftyrs_sqlite_metadata")

    static let id = Expression<Int64>("id")
    static let documentName = Expression<String>("document_name")
    static let updateEncoding = Expression<String>("update_encoding")
    static let updateKind = Expression<String>("update_kind")
    static let update = Expression<Blob>("update")
    static let insertedAt = Expression<Double>("inserted_at")
    static let metadataKey = Expression<String>("metadata_key")
    static let metadataValue = Expression<Blob>("metadata_value")
    static let updatedAt = Expression<Double>("updated_at")

    static func create(on connection: Connection) throws {
        try connection.run(updates.create(ifNotExists: true) { table in
            table.column(id, primaryKey: .autoincrement)
            table.column(documentName)
            table.column(updateEncoding)
            table.column(updateKind)
            table.column(update)
            table.column(insertedAt)
        })
        try connection.run(updates.createIndex(documentName, ifNotExists: true))

        try connection.run(metadata.create(ifNotExists: true) { table in
            table.column(documentName)
            table.column(metadataKey)
            table.column(metadataValue)
            table.column(updatedAt)
            table.primaryKey(documentName, metadataKey)
        })
    }

    static func loadUpdates(for name: String, from connection: Connection) throws -> [YUpdate] {
        try connection.prepare(
            updates
                .filter(documentName == name)
                .order(id.asc)
        ).map { row in
            let kind = row[updateKind]
            guard SQLiteUpdateKind(rawValue: kind) != nil else {
                throw SQLiteProviderError.unknownUpdateKind(kind)
            }
            let encoding = row[updateEncoding]
            let bytes = Data(row[update].bytes)
            guard !bytes.isEmpty else {
                throw SQLiteProviderError.emptyUpdateBlob
            }
            switch encoding {
            case "v1":
                return .v1(bytes)
            default:
                throw SQLiteProviderError.unknownUpdateEncoding(encoding)
            }
        }
    }

    static func append(_ value: YUpdate, kind: SQLiteUpdateKind, documentName name: String, on connection: Connection) throws {
        guard !value.data.isEmpty else {
            throw SQLiteProviderError.emptyUpdateBlob
        }
        let encoding: String
        switch value.encoding {
        case .v1:
            encoding = "v1"
        case .v2:
            throw SQLiteProviderError.unknownUpdateEncoding("v2")
        }
        try connection.run(updates.insert(
            documentName <- name,
            updateEncoding <- encoding,
            updateKind <- kind.rawValue,
            update <- Blob(bytes: Array(value.data)),
            insertedAt <- Date().timeIntervalSince1970
        ))
    }

    static func updateCount(documentName name: String, on connection: Connection) throws -> Int {
        try connection.scalar(updates.filter(documentName == name).count)
    }

    static func maxUpdateID(documentName name: String, on connection: Connection) throws -> Int64? {
        try connection.pluck(
            updates
                .select(id)
                .filter(documentName == name)
                .order(id.desc)
                .limit(1)
        )?[id]
    }

    static func compact(
        documentName name: String,
        snapshot: YUpdate,
        compactedThroughID: Int64?,
        on connection: Connection
    ) throws {
        try connection.transaction {
            if let compactedThroughID {
                try connection.run(
                    updates
                        .filter(documentName == name && id <= compactedThroughID)
                        .delete()
                )
            }
            try append(snapshot, kind: .snapshot, documentName: name, on: connection)
        }
    }

    static func setMetadata(_ value: Data, forKey key: String, documentName name: String, on connection: Connection) throws {
        try connection.run(metadata.insert(
            or: .replace,
            documentName <- name,
            metadataKey <- key,
            metadataValue <- Blob(bytes: Array(value)),
            updatedAt <- Date().timeIntervalSince1970
        ))
    }

    static func metadata(forKey key: String, documentName name: String, from connection: Connection) throws -> Data? {
        guard let row = try connection.pluck(metadata.filter(documentName == name && metadataKey == key)) else {
            return nil
        }
        return Data(row[metadataValue].bytes)
    }

    static func removeMetadata(forKey key: String, documentName name: String, on connection: Connection) throws {
        try connection.run(metadata.filter(documentName == name && metadataKey == key).delete())
    }
}
