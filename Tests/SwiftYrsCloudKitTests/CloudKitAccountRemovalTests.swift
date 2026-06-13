#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import Testing

private struct Harness {
    let engine: MockCloudKitSyncEngine
    let store: CloudKitSyncStore
    let codec: CloudKitRecordCodec
    let metadata: FileCloudKitMetadataStore

    static func make() async -> Harness {
        let engine = MockCloudKitSyncEngine()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftyrs-ck-account-\(UUID().uuidString)")
        let codec = CloudKitRecordCodec(assetDirectory: dir.appendingPathComponent("assets"))
        let metadata = FileCloudKitMetadataStore(directory: dir.appendingPathComponent("meta"))
        let store = CloudKitSyncStore(adapter: engine, codec: codec, metadataStore: metadata)
        await store.start()
        return Harness(engine: engine, store: store, codec: codec, metadata: metadata)
    }

    func provider(clientID: UInt64 = 7, documentName: String = "doc") -> (CloudKitProvider, YDoc) {
        let doc = YDoc(clientID: clientID)
        let provider = CloudKitProvider(
            documentName: documentName, doc: doc, store: store,
            options: CloudKitProviderOptions(debounce: .seconds(600))
        )
        return (provider, doc)
    }
}

private func insert(_ string: String, into doc: YDoc) throws {
    let text = try doc.text(named: "body")
    try doc.write { try $0.insert(string, into: text, at: 0) }
}

@Test
func accountChangeStreamReflectsMockEvents() async throws {
    let h = await Harness.make()
    let (provider, _) = h.provider()
    try await provider.start()
    defer { Task { await provider.destroy() } }

    var iterator = provider.accountChanges.makeAsyncIterator()
    await h.engine.simulateAccountChange(.switchAccounts)
    #expect(await iterator.next() == .switchAccounts)
}

@Test
func accountSwitchStopsSyncAndDoesNotLeakTheExistingDoc() async throws {
    let h = await Harness.make()
    let (provider, doc) = h.provider()
    try await provider.start()
    defer { Task { await provider.destroy() } }

    await h.engine.simulateAccountChange(.switchAccounts)

    // Edits made after the switch must not be uploaded to the new account.
    try insert("private", into: doc)
    try await provider.flush()
    #expect(await h.engine.serverRecordIDs.isEmpty)
    #expect(await h.engine.pendingSaveIDs.isEmpty)
}

@Test
func accountSwitchClearsLocalSyncState() async throws {
    let h = await Harness.make()
    let (provider, doc) = h.provider()
    try await provider.start()

    // Establish some local sync state first.
    try insert("x", into: doc)
    try await provider.flush()
    #expect(try h.metadata.data(
        forKey: CloudKitSyncStateKeys.engineState,
        documentName: CloudKitSyncStateKeys.storeNamespace
    ) != nil)

    await h.engine.simulateAccountChange(.switchAccounts)

    // Both per-document drain set and store-level engine state are cleared.
    #expect(try h.metadata.data(
        forKey: CloudKitSyncStateKeys.drainSet, documentName: "doc"
    ) == nil)
    #expect(try h.metadata.data(
        forKey: CloudKitSyncStateKeys.engineState,
        documentName: CloudKitSyncStateKeys.storeNamespace
    ) == nil)

    await provider.destroy()
}

@Test
func removeDocumentDeletesTheZoneAndRecords() async throws {
    let h = await Harness.make()
    let (provider, doc) = h.provider()
    try await provider.start()

    try insert("hello", into: doc)
    try await provider.flush()
    #expect(await !h.engine.serverRecordIDs.isEmpty)

    await provider.destroy() // no active provider before removal

    try await h.store.removeDocument(named: "doc")

    let zoneID = h.codec.zoneID(forDocumentName: "doc")
    #expect(await h.engine.serverRecordIDs.allSatisfy { $0.zoneID != zoneID })
    #expect(try h.metadata.data(forKey: CloudKitSyncStateKeys.drainSet, documentName: "doc") == nil)
}

@Test
func removeDocumentRejectsAnActiveProvider() async throws {
    let h = await Harness.make()
    let (provider, _) = h.provider(documentName: "live")
    try await provider.start()
    defer { Task { await provider.destroy() } }

    await #expect(throws: CloudKitProviderError.activeProvider(documentName: "live")) {
        try await h.store.removeDocument(named: "live")
    }
}
#endif
