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

/// An observed update that is not on disk yet.
public struct SQLitePendingUpdate: Sendable, Equatable {
    /// The update's position among those the provider observed, from 1.
    public let sequence: UInt64
    public let update: YUpdate
}

/// The outcome of one attempt to write one observed update.
public enum SQLiteWriteResult: Sendable {
    case persisted(sequence: UInt64)
    /// The update stays pending and is retried.
    case failed(sequence: UInt64, error: any Error)

    public var sequence: UInt64 {
        switch self {
        case let .persisted(sequence), let .failed(sequence, _):
            sequence
        }
    }
}

/// Thrown by `SQLiteProvider.flush()` and `close()` when observed updates are
/// still not on disk.
public struct SQLiteFlushError: Error {
    /// The unsaved updates, oldest first.
    public let unsavedUpdates: [SQLitePendingUpdate]
    /// The error from the last write attempt.
    public let underlyingError: any Error
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

    public func setMetadata(_ value: Data, forKey key: String, documentName: String) throws {
        try sync { connection in
            try SQLiteSchema.create(on: connection)
            try SQLiteSchema.setMetadata(value, forKey: key, documentName: documentName, on: connection)
        }
    }

    public func metadata(forKey key: String, documentName: String) throws -> Data? {
        try sync { connection in
            try SQLiteSchema.create(on: connection)
            return try SQLiteSchema.metadata(forKey: key, documentName: documentName, from: connection)
        }
    }

    public func removeMetadata(forKey key: String, documentName: String) throws {
        try sync { connection in
            try SQLiteSchema.create(on: connection)
            try SQLiteSchema.removeMetadata(forKey: key, documentName: documentName, on: connection)
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
    /// One result for each attempt to write an observed update, in attempt
    /// order. Keeps only the newest 256 results while nobody reads it, so use
    /// `pendingUpdateCount` and `flush()` for the authoritative state.
    public let writeResults: AsyncStream<SQLiteWriteResult>

    public private(set) var isStarted = false

    /// Observed updates that are not on disk yet, including a write in progress.
    public var pendingUpdateCount: Int {
        stateLock.withLock { pendingUpdates.count }
    }

    var testHooks = SQLiteProviderTestHooks()

    private let syncedContinuation: AsyncStream<Bool>.Continuation
    private let errorsContinuation: AsyncStream<Error>.Continuation
    private let writeResultsContinuation: AsyncStream<SQLiteWriteResult>.Continuation
    private var observation: Observation?
    private var destroyed = false
    /// The teardown every `close()` call awaits.
    private var closeTask: Task<Error?, Never>?
    private let lifecycleLock = NSLock()

    // Write state, guarded by `stateLock`.
    private let stateLock = NSLock()
    private var acceptingUpdates = false
    private var nextSequence: UInt64 = 1
    private var pendingUpdates: [SQLitePendingUpdate] = []
    /// Rows this provider loaded or wrote. The document contains all of them,
    /// so they are the only rows its compaction may replace.
    private var knownRowIDs: Set<Int64> = []
    private var autoCompactionScheduled = false
    /// Set when `close()` starts; later `compact()` calls are rejected.
    private var closing = false

    /// Serializes write attempts, so updates reach the store in observed order.
    private let writeLock = NSLock()
    private let compactionLock = NSLock()
    /// Runs auto-compaction and the async API, one job at a time.
    private let backgroundQueue = DispatchQueue(label: "SwiftYrsSQLite.SQLiteProvider", qos: .utility)

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

        let writeResultsPair = AsyncStream.makeStream(
            of: SQLiteWriteResult.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        self.writeResults = writeResultsPair.stream
        self.writeResultsContinuation = writeResultsPair.continuation
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
            let rows = try store.sync { connection in
                try SQLiteSchema.loadUpdates(for: documentName, from: connection)
            }
            for row in rows {
                try doc.apply(row.update)
            }
            stateLock.withLock {
                knownRowIDs = Set(rows.map(\.id))
                acceptingUpdates = true
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
            stateLock.withLock { acceptingUpdates = false }
            observation?.cancel()
            observation = nil
            if registered {
                store.unregisterProvider(documentName: documentName)
            }
            lifecycleLock.unlock()
            throw error
        }
    }

    /// Replaces the rows this provider has loaded or written with one
    /// snapshot of its document, on the caller's thread.
    ///
    /// Rows another session wrote in the meantime are kept, even if that
    /// session compacted them, so a stale compaction cannot drop newer content.
    /// Throws `SQLiteProviderError.destroyed` once `close()` has started.
    public func compact() throws {
        compactionLock.lock()
        defer { compactionLock.unlock() }
        // Checked under the lock `close()` joins, so an admitted compaction
        // always finishes before the document is released.
        guard !stateLock.withLock({ closing }) else {
            throw SQLiteProviderError.destroyed
        }
        try compactLocked()
    }

    /// Runs on the background queue, which `close()` drains, so it skips the
    /// `closing` check.
    private func compactOnBackgroundQueue() throws {
        compactionLock.lock()
        defer { compactionLock.unlock() }
        try compactLocked()
    }

    private func compactLocked() throws {
        // Capture the rows before encoding: the snapshot then covers each of them.
        let replacedRowIDs = stateLock.withLock { knownRowIDs }
        let snapshot = try encodeSnapshot()
        testHooks.willCommitCompaction?()
        let snapshotRowID = try store.sync { connection in
            try SQLiteSchema.compact(
                documentName: documentName,
                snapshot: snapshot,
                replacing: replacedRowIDs,
                on: connection
            )
        }
        stateLock.withLock {
            knownRowIDs.subtract(replacedRowIDs)
            knownRowIDs.insert(snapshotRowID)
        }
    }

    /// Runs `compact()` off the caller's thread, after any auto-compaction in
    /// progress, and returns once the snapshot is on disk.
    public func compactAndWait() async throws {
        // Admitted and queued atomically with `closing`, so a compaction
        // admitted before `close()` runs ahead of its flush.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let admitted = stateLock.withLock { () -> Bool in
                guard !closing else {
                    return false
                }
                backgroundQueue.async {
                    do {
                        try self.compactOnBackgroundQueue()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                return true
            }
            if !admitted {
                continuation.resume(throwing: SQLiteProviderError.destroyed)
            }
        }
    }

    /// Writes every update observed so far and waits for auto-compaction.
    ///
    /// Failed writes stay pending in observed order. Each later observed
    /// update and each `flush()` retries them, oldest first, ahead of newer
    /// updates. If they still fail, this throws `SQLiteFlushError` naming the
    /// unsaved updates.
    public func flush() async throws {
        try await onBackgroundQueue { try self.writePendingUpdatesOrThrow() }
        // A write above may have scheduled an auto-compaction; it runs first.
        try await onBackgroundQueue {}
    }

    public func setMetadata(_ value: Data, forKey key: String) throws {
        try store.setMetadata(value, forKey: key, documentName: documentName)
    }

    public func metadata(forKey key: String) throws -> Data? {
        try store.metadata(forKey: key, documentName: documentName)
    }

    public func removeMetadata(forKey key: String) throws {
        try store.removeMetadata(forKey: key, documentName: documentName)
    }

    /// Stops observing the document, then waits for pending writes and for
    /// compaction in progress, including a synchronous `compact()`, before
    /// releasing the document name and finishing the streams.
    ///
    /// Throws `SQLiteFlushError` if updates are still unsaved. The provider is
    /// closed either way; the error carries the updates, so the caller can
    /// store them another way. Concurrent and later calls await the same
    /// teardown and its result.
    public func close() async throws {
        let task = lifecycleLock.withLock { () -> Task<Error?, Never> in
            if let closeTask {
                return closeTask
            }
            let wasStarted = beginTeardownLocked()
            stateLock.withLock { closing = true }
            let task = Task { await self.performClose(wasStarted: wasStarted) }
            closeTask = task
            return task
        }
        if let error = await task.value {
            throw error
        }
    }

    /// Stops observing the document and releases the document name at once.
    /// It does not wait for writes or compaction; use `close()` for that.
    public func destroy() {
        guard let wasStarted = lifecycleLock.withLock({ beginTeardownLocked() }) else {
            return
        }
        cancelObservation()
        finishTeardown(wasStarted: wasStarted)
    }

    deinit {
        destroy()
    }

    /// Marks the provider destroyed and stops accepting updates. Call with
    /// `lifecycleLock` held. Returns whether the provider was started, or nil
    /// if it was already destroyed.
    private func beginTeardownLocked() -> Bool? {
        guard !destroyed else {
            return nil
        }
        destroyed = true
        let wasStarted = isStarted
        isStarted = false
        stateLock.withLock { acceptingUpdates = false }
        return wasStarted
    }

    private func cancelObservation() {
        observation?.cancel()
        observation = nil
    }

    private func performClose(wasStarted: Bool?) async -> Error? {
        if wasStarted != nil {
            cancelObservation()
        }
        var flushError: Error?
        do {
            try await flush()
        } catch {
            flushError = error
        }
        // Join a synchronous compact() admitted before `closing` was set.
        try? await onBackgroundQueue {
            self.compactionLock.lock()
            self.compactionLock.unlock()
        }
        if let wasStarted {
            testHooks.willReleaseDocument?()
            finishTeardown(wasStarted: wasStarted)
        }
        return flushError
    }

    private func finishTeardown(wasStarted: Bool) {
        if wasStarted {
            store.unregisterProvider(documentName: documentName)
        }
        syncedContinuation.finish()
        errorsContinuation.finish()
        writeResultsContinuation.finish()
    }

    private func persistObservedUpdate(_ update: YUpdate) {
        let accepted = stateLock.withLock { () -> Bool in
            guard acceptingUpdates else {
                return false
            }
            pendingUpdates.append(SQLitePendingUpdate(sequence: nextSequence, update: update))
            nextSequence += 1
            return true
        }
        if accepted {
            writePendingUpdates()
        }
    }

    private func writePendingUpdatesOrThrow() throws {
        guard let error = writePendingUpdates() else {
            return
        }
        let unsaved = stateLock.withLock { pendingUpdates }
        throw SQLiteFlushError(unsavedUpdates: unsaved, underlyingError: error)
    }

    /// Writes every pending update in one transaction, oldest first. On
    /// failure the updates stay pending and the error is returned.
    @discardableResult
    private func writePendingUpdates() -> Error? {
        writeLock.lock()
        defer { writeLock.unlock() }

        let batch = stateLock.withLock { pendingUpdates }
        guard !batch.isEmpty else {
            return nil
        }
        testHooks.willWriteUpdates?()
        do {
            let (rowIDs, count) = try store.sync { connection in
                var rowIDs: [Int64] = []
                var count = 0
                // Count inside the transaction: a failure after commit would
                // retry rows that are already on disk.
                try connection.transaction {
                    for pending in batch {
                        rowIDs.append(try SQLiteSchema.append(
                            pending.update,
                            kind: .incremental,
                            documentName: documentName,
                            on: connection
                        ))
                    }
                    try testHooks.willCountUpdates?()
                    count = try SQLiteSchema.updateCount(documentName: documentName, on: connection)
                }
                return (rowIDs, count)
            }
            let shouldCompact = stateLock.withLock { () -> Bool in
                // Only this method removes pending updates, so the batch is still the prefix.
                pendingUpdates.removeFirst(batch.count)
                knownRowIDs.formUnion(rowIDs)
                guard acceptingUpdates, options.autoCompact, count >= options.compactThreshold,
                      !autoCompactionScheduled else {
                    return false
                }
                autoCompactionScheduled = true
                return true
            }
            for pending in batch {
                writeResultsContinuation.yield(.persisted(sequence: pending.sequence))
            }
            // Scheduled under `writeLock`, so a flush that writes after this
            // also waits for the compaction.
            if shouldCompact {
                scheduleAutoCompaction()
            }
            return nil
        } catch {
            for pending in batch {
                writeResultsContinuation.yield(.failed(sequence: pending.sequence, error: error))
            }
            errorsContinuation.yield(error)
            return error
        }
    }

    private func scheduleAutoCompaction() {
        backgroundQueue.async { [weak self] in
            guard let self else { return }
            defer { self.stateLock.withLock { self.autoCompactionScheduled = false } }
            do {
                try self.compactOnBackgroundQueue()
            } catch {
                self.errorsContinuation.yield(error)
            }
        }
    }

    /// Auto-compaction can start while the write that triggered it is still
    /// committing, so wait briefly for that transaction to finish.
    private func encodeSnapshot() throws -> YUpdate {
        let deadline = ContinuousClock.now + .seconds(1)
        while true {
            do {
                return try doc.encodeStateAsUpdateV1()
            } catch YError.transactionConflict where ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    private func onBackgroundQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            backgroundQueue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct SQLiteProviderTestHooks {
    var willWriteUpdates: (@Sendable () -> Void)?
    var willCommitCompaction: (@Sendable () -> Void)?
    var willCountUpdates: (@Sendable () throws -> Void)?
    var willReleaseDocument: (@Sendable () -> Void)?
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

    static func loadUpdates(for name: String, from connection: Connection) throws -> [(id: Int64, update: YUpdate)] {
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
                return (row[id], .v1(bytes))
            default:
                throw SQLiteProviderError.unknownUpdateEncoding(encoding)
            }
        }
    }

    @discardableResult
    static func append(_ value: YUpdate, kind: SQLiteUpdateKind, documentName name: String, on connection: Connection) throws -> Int64 {
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
        return try connection.run(updates.insert(
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

    /// Deletes `rowIDs` and appends `snapshot` in one transaction, returning
    /// the snapshot's row ID. Rows not in `rowIDs` are kept.
    @discardableResult
    static func compact(
        documentName name: String,
        snapshot: YUpdate,
        replacing rowIDs: Set<Int64>,
        on connection: Connection
    ) throws -> Int64 {
        let rowIDs = Array(rowIDs)
        var snapshotRowID: Int64 = 0
        try connection.transaction {
            // Chunked to stay under SQLite's bound-parameter limit.
            for start in stride(from: 0, to: rowIDs.count, by: 500) {
                let chunk = Array(rowIDs[start..<min(start + 500, rowIDs.count)])
                try connection.run(
                    updates
                        .filter(documentName == name && chunk.contains(id))
                        .delete()
                )
            }
            snapshotRowID = try append(snapshot, kind: .snapshot, documentName: name, on: connection)
        }
        return snapshotRowID
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
