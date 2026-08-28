#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import Testing

/// The inbound spool: a fetch for a document with no attached provider must not
/// be dropped while the engine's change token advances (ADR-0025).
private struct Vault {
    let engine: MockCloudKitSyncEngine
    let store: CloudKitSyncStore
    let codec: CloudKitRecordCodec
    let metadata: FileCloudKitMetadataStore
    let directory: URL

    static func make(directory: URL? = nil) async throws -> Vault {
        let engine = MockCloudKitSyncEngine()
        let directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftyrs-ck-spool-\(UUID().uuidString)")
        let codec = try CloudKitRecordCodec(
            zoneName: "vault",
            assetDirectory: directory.appendingPathComponent("assets")
        )
        let metadata = FileCloudKitMetadataStore(directory: directory.appendingPathComponent("meta"))
        let store = CloudKitSyncStore(adapter: engine, codec: codec, metadataStore: metadata)
        await store.start()
        return Vault(engine: engine, store: store, codec: codec, metadata: metadata, directory: directory)
    }

    func page(_ documentName: String, clientID: UInt64) throws -> (CloudKitProvider, YDoc) {
        let doc = YDoc(clientID: clientID)
        let provider = try CloudKitProvider(
            documentName: documentName,
            doc: doc,
            store: store,
            options: CloudKitProviderOptions(debounce: .seconds(600))
        )
        return (provider, doc)
    }

    /// Pull remote changes with no provider attached, the way a store-level
    /// background fetch does.
    func fetch() async throws {
        try await engine.fetchChanges()
    }

    /// How many changes are waiting on disk for `documentName`, read back out
    /// of the metadata store the spool persists through.
    func spooledEntryCount(forDocument documentName: String) throws -> Int {
        guard let data = try metadata.data(
            forKey: CloudKitSyncStateKeys.inboundSpool,
            documentName: documentName
        ), let spool = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let changes = spool["changes"] as? [Any]
        else {
            return 0
        }
        return changes.count
    }
}

private func insert(_ string: String, at index: UInt32, into doc: YDoc) throws {
    let text = try doc.text(named: "body")
    try doc.write { try $0.insert(string, into: text, at: index) }
}

private func text(_ doc: YDoc) throws -> String {
    let text = try doc.text(named: "body")
    return try doc.read { try $0.string(from: text) }
}

private func remoteIncremental(
    _ contents: String,
    documentName: String,
    clientID: UInt64,
    codec: CloudKitRecordCodec
) throws -> CKRecord {
    let other = YDoc(clientID: clientID)
    try insert(contents, at: 0, into: other)
    return try codec.encodeIncremental(
        CloudKitIncrementalRecordPayload(
            documentName: documentName,
            clientID: clientID,
            fromClock: 0,
            toClock: try other.clientClock(clientID: clientID),
            update: try other.encodeClientStateAsUpdateV1(clientID: clientID, fromClock: 0)
        )
    )
}

@Test
func aRemoteEditToAClosedDocumentSurvivesUntilItsProviderStarts() async throws {
    let vault = try await Vault.make()

    await vault.engine.simulateRemoteModification(
        try remoteIncremental("remote", documentName: "closed-page", clientID: 9, codec: vault.codec)
    )
    try await vault.fetch()
    #expect(try vault.spooledEntryCount(forDocument: "closed-page") == 1)

    let (page, doc) = try vault.page("closed-page", clientID: 1)
    try await page.start()
    defer { Task { await page.destroy() } }

    #expect(try text(doc) == "remote")
    // Drained entries are cleared, not replayed forever.
    #expect(try vault.spooledEntryCount(forDocument: "closed-page") == 0)
}

@Test
func spooledEntriesReplayInArrivalOrder() async throws {
    let vault = try await Vault.make()

    // One writer, three sequential edits: applying them out of order would not
    // build "abc" (each update depends on the clocks before it).
    let author = YDoc(clientID: 9)
    var records: [CKRecord] = []
    for (index, fragment) in ["a", "b", "c"].enumerated() {
        try insert(fragment, at: UInt32(index), into: author)
        records.append(
            try vault.codec.encodeIncremental(
                CloudKitIncrementalRecordPayload(
                    documentName: "page",
                    clientID: 9,
                    fromClock: UInt32(index),
                    toClock: try author.clientClock(clientID: 9),
                    update: try author.encodeClientStateAsUpdateV1(clientID: 9, fromClock: UInt32(index))
                )
            )
        )
    }
    for record in records {
        await vault.engine.simulateRemoteModification(record)
        try await vault.fetch()
    }
    #expect(try vault.spooledEntryCount(forDocument: "page") == 3)

    let (page, doc) = try vault.page("page", clientID: 1)
    try await page.start()
    defer { Task { await page.destroy() } }

    #expect(try text(doc) == "abc")
}

@Test
func aDeletionTombstoneIsSpooledAndReplayed() async throws {
    let vault = try await Vault.make()

    let record = try remoteIncremental("remote", documentName: "page", clientID: 9, codec: vault.codec)
    await vault.engine.simulateRemoteModification(record)
    try await vault.fetch()
    await vault.engine.simulateRemoteDeletion(record.recordID)
    try await vault.fetch()

    #expect(try vault.spooledEntryCount(forDocument: "page") == 2)

    let (page, doc) = try vault.page("page", clientID: 1)
    try await page.start()
    defer { Task { await page.destroy() } }

    // The tombstone is GC of a subsumed incremental, so the content stays.
    #expect(try text(doc) == "remote")
    #expect(try vault.spooledEntryCount(forDocument: "page") == 0)
}

@Test
func spooledEntriesSurviveARelaunch() async throws {
    let vault = try await Vault.make()
    await vault.engine.simulateRemoteModification(
        try remoteIncremental("remote", documentName: "page", clientID: 9, codec: vault.codec)
    )
    try await vault.fetch()

    // A new store on the same metadata directory — the process restarted.
    let relaunched = try await Vault.make(directory: vault.directory)
    let (page, doc) = try relaunched.page("page", clientID: 1)
    try await page.start()
    defer { Task { await page.destroy() } }

    #expect(try text(doc) == "remote")
}

@Test
func aSpooledSnapshotDropsTheIncrementalsItCovers() async throws {
    let vault = try await Vault.make()

    let author = YDoc(clientID: 9)
    try insert("covered", at: 0, into: author)
    let incremental = try vault.codec.encodeIncremental(
        CloudKitIncrementalRecordPayload(
            documentName: "page",
            clientID: 9,
            fromClock: 0,
            toClock: try author.clientClock(clientID: 9),
            update: try author.encodeClientStateAsUpdateV1(clientID: 9, fromClock: 0)
        )
    )
    await vault.engine.simulateRemoteModification(incremental)
    try await vault.fetch()

    // A later edit that only the snapshot carries, so the snapshot is not just
    // a rewrite of the covered incremental.
    try insert(" and more", at: 7, into: author)
    let snapshot = try vault.codec.encodeSnapshot(
        CloudKitSnapshotRecordPayload(
            documentName: "page",
            update: try author.encodeStateAsUpdateV1(),
            stateVector: try author.stateVector()
        )
    )
    await vault.engine.simulateRemoteModification(snapshot)
    try await vault.fetch()

    // The snapshot's state vector covers the incremental, which is dropped.
    #expect(try vault.spooledEntryCount(forDocument: "page") == 1)

    let (page, doc) = try vault.page("page", clientID: 1)
    try await page.start()
    defer { Task { await page.destroy() } }

    #expect(try text(doc) == "covered and more")
}

@Test
func anIncrementalTheSnapshotDoesNotCoverIsKept() async throws {
    let vault = try await Vault.make()

    let snapshotAuthor = YDoc(clientID: 9)
    try insert("base", at: 0, into: snapshotAuthor)
    await vault.engine.simulateRemoteModification(
        try vault.codec.encodeSnapshot(
            CloudKitSnapshotRecordPayload(
                documentName: "page",
                update: try snapshotAuthor.encodeStateAsUpdateV1(),
                stateVector: try snapshotAuthor.stateVector()
            )
        )
    )
    try await vault.fetch()

    // A different writer's edit, which no state vector of client 9 covers.
    await vault.engine.simulateRemoteModification(
        try remoteIncremental("!", documentName: "page", clientID: 11, codec: vault.codec)
    )
    try await vault.fetch()
    #expect(try vault.spooledEntryCount(forDocument: "page") == 2)

    let (page, doc) = try vault.page("page", clientID: 1)
    try await page.start()
    defer { Task { await page.destroy() } }

    #expect(try text(doc).contains("base"))
    #expect(try text(doc).contains("!"))
}

@Test
func spooledEntriesGoWhenTheirDocumentIsRemoved() async throws {
    let vault = try await Vault.make()
    await vault.engine.simulateRemoteModification(
        try remoteIncremental("remote", documentName: "page", clientID: 9, codec: vault.codec)
    )
    try await vault.fetch()
    #expect(try vault.spooledEntryCount(forDocument: "page") == 1)

    try await vault.store.removeDocument(named: "page")
    #expect(try vault.spooledEntryCount(forDocument: "page") == 0)
}

@Test
func aFetchForAnAttachedProviderAppliesAtOnceAndLeavesNothingSpooled() async throws {
    let vault = try await Vault.make()
    let (page, doc) = try vault.page("page", clientID: 1)
    try await page.start()
    defer { Task { await page.destroy() } }

    await vault.engine.simulateRemoteModification(
        try remoteIncremental("live", documentName: "page", clientID: 9, codec: vault.codec)
    )
    try await page.fetch()

    #expect(try text(doc) == "live")
    // Every fetch is spooled before it is applied, and dropped once it is.
    #expect(try vault.spooledEntryCount(forDocument: "page") == 0)
}

@Test
func anEntryIsStillSpooledWhileItIsBeingApplied() async throws {
    let vault = try await Vault.make()
    await vault.engine.simulateRemoteModification(
        try remoteIncremental("remote", documentName: "page", clientID: 9, codec: vault.codec)
    )
    try await vault.fetch()

    let (page, doc) = try vault.page("page", clientID: 1)

    // The update observer fires synchronously inside the apply, which is
    // exactly the window a crash would land in. If the spool were cleared
    // before the apply, the update would be lost on relaunch.
    let spooledDuringApply = Locked(0)
    let observation = try doc.observeUpdates { event in
        guard case .update = event else { return }
        spooledDuringApply.value = (try? vault.spooledEntryCount(forDocument: "page")) ?? -1
    }
    defer { observation.cancel() }

    try await page.start()
    defer { Task { await page.destroy() } }

    #expect(spooledDuringApply.value == 1)
    #expect(try vault.spooledEntryCount(forDocument: "page") == 0)
}

/// A box for reading a value written from a synchronous native callback.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
#endif
