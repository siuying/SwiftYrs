import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import SwiftYrsSQLite
import SQLite

/// One todo, rendered by SwiftUI. The CRDT is the source of truth; this is a
/// read-only snapshot keyed by the item's stable `id`.
struct TodoItem: Identifiable, Equatable {
    let id: String
    var title: String
    var completed: Bool
}

/// Owns the shared todo document and bridges it to SwiftUI.
///
/// Todos are a top-level `YArray("todos")` of nested `YMap { id, title, completed }`
/// (ADR-0024 modelling). `SQLiteProvider` persists the document locally and
/// reconstructs it on launch — which must happen *before* `CloudKitProvider`
/// starts, so the CloudKit recovery drain can see any un-uploaded edits.
/// `CloudKitProvider` then propagates the document across the user's devices via
/// the real `CKSyncEngine` adapter.
@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = []
    @Published private(set) var isSynced = false
    @Published private(set) var accountSignedOut = false

    private let documentName: String
    private let containerIdentifier: String
    private let doc: YDoc
    private let todos: YArray

    private var sqliteProvider: SQLiteProvider?
    private var cloudKitStore: CloudKitSyncStore?
    private var cloudKitProvider: CloudKitProvider?
    private var observation: Observation?
    private var observerTasks: [Task<Void, Never>] = []

    init(
        documentName: String = "todos",
        containerIdentifier: String = "iCloud.com.swiftyrs.TodoCloudKit"
    ) throws {
        self.documentName = documentName
        self.containerIdentifier = containerIdentifier
        self.doc = YDoc()
        self.todos = try doc.array(named: "todos")
    }

    /// Wire local persistence first (reconstructing the doc), then CloudKit.
    func start() async {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let dbURL = support.appendingPathComponent("\(documentName).sqlite3")
            let sqliteStore = try SQLiteStore(Connection(dbURL.path))
            let sqlite = SQLiteProvider(documentName: documentName, doc: doc, store: sqliteStore)
            try sqlite.start() // reconstructs the doc from the local log
            self.sqliteProvider = sqlite

            let metadataURL = support.appendingPathComponent("cloudkit-metadata", isDirectory: true)
            let ckStore = CloudKitSyncStore(
                adapter: CKSyncEngineAdapter(containerIdentifier: containerIdentifier),
                codec: CloudKitRecordCodec(assetDirectory: support.appendingPathComponent("cloudkit-assets")),
                metadataStore: FileCloudKitMetadataStore(directory: metadataURL)
            )
            await ckStore.start()
            let ckProvider = CloudKitProvider(documentName: documentName, doc: doc, store: ckStore)
            try await ckProvider.start()
            self.cloudKitStore = ckStore
            self.cloudKitProvider = ckProvider

            observe(provider: ckProvider)
        } catch {
            print("TodoStore start failed: \(error)")
        }

        refresh()
    }

    // MARK: Mutations

    func add(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? doc.write { txn in
            let count = try txn.count(of: todos)
            let item = try txn.insertMap(into: todos, at: count)
            try txn.set(.string(UUID().uuidString), forKey: "id", in: item)
            try txn.set(.string(trimmed), forKey: "title", in: item)
            try txn.set(.bool(false), forKey: "completed", in: item)
        }
        refresh()
    }

    func toggle(_ id: String) {
        mutateItem(id) { txn, item, current in
            try txn.set(.bool(!current.completed), forKey: "completed", in: item)
        }
    }

    func rename(_ id: String, to title: String) {
        mutateItem(id) { txn, item, _ in
            try txn.set(.string(title), forKey: "title", in: item)
        }
    }

    func delete(_ id: String) {
        try? doc.write { txn in
            guard let index = try Self.index(of: id, in: todos, txn: txn) else { return }
            try txn.remove(from: todos, at: index, length: 1)
        }
        refresh()
    }

    // MARK: Internals

    private func mutateItem(
        _ id: String,
        _ body: @escaping (YWriteTransaction, YMap, TodoItem) throws -> Void
    ) {
        try? doc.write { txn in
            guard let index = try Self.index(of: id, in: todos, txn: txn),
                  case let .map(item) = try txn.get(index, from: todos) else { return }
            let snapshot = try Self.snapshot(of: item, txn: txn)
            try body(txn, item, snapshot)
        }
        refresh()
    }

    private func observe(provider: CloudKitProvider) {
        // Refresh the UI whenever the document changes (local or remote). The
        // commit callback fires on the committing thread, so it only hops to the
        // main actor — it never opens a transaction.
        observation = try? doc.observeUpdates { [weak self] event in
            guard case .update = event else { return }
            Task { @MainActor in self?.refresh() }
        }
        observerTasks.append(Task { [weak self] in
            for await synced in provider.synced { await MainActor.run { self?.isSynced = synced } }
        })
        observerTasks.append(Task { [weak self] in
            for await change in provider.accountChanges {
                await MainActor.run { self?.accountSignedOut = (change != .signIn) }
            }
        })
    }

    private func refresh() {
        items = (try? doc.read { txn in try Self.readAll(from: todos, txn: txn) }) ?? []
    }

    private static func readAll(from array: YArray, txn: YReadTransaction) throws -> [TodoItem] {
        let count = try txn.count(of: array)
        guard count > 0 else { return [] }
        return try (0..<count).compactMap { index in
            guard case let .map(map) = try txn.get(index, from: array) else { return nil }
            return try snapshot(of: map, txn: txn)
        }
    }

    private static func snapshot(of map: YMap, txn: YReadTransaction) throws -> TodoItem {
        TodoItem(
            id: string(try txn.get("id", from: map)),
            title: string(try txn.get("title", from: map)),
            completed: bool(try txn.get("completed", from: map))
        )
    }

    private static func index(of id: String, in array: YArray, txn: YReadTransaction) throws -> UInt32? {
        let count = try txn.count(of: array)
        for index in 0..<count {
            guard case let .map(map) = try txn.get(index, from: array) else { continue }
            if string(try txn.get("id", from: map)) == id { return index }
        }
        return nil
    }

    private static func string(_ value: YValue) -> String {
        if case let .string(string) = value { return string }
        return ""
    }

    private static func bool(_ value: YValue) -> Bool {
        if case let .bool(bool) = value { return bool }
        return false
    }
}
