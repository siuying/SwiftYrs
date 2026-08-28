#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import Testing

/// One store, one zone, many documents: routing, spool-free dispatch, and the
/// two grains of removal (ADR-0025).
private struct Vault {
    let engine: MockCloudKitSyncEngine
    let store: CloudKitSyncStore
    let codec: CloudKitRecordCodec
    let metadata: FileCloudKitMetadataStore
    let directory: URL

    static func make(zoneName: String = "vault", directory: URL? = nil) async throws -> Vault {
        let engine = MockCloudKitSyncEngine()
        let directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftyrs-ck-multidoc-\(UUID().uuidString)")
        let codec = try CloudKitRecordCodec(
            zoneName: zoneName,
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

    /// The record names the store believes `documentName` owns, read back out of
    /// the metadata store the registry persists through.
    func knownRecordNames(forDocument documentName: String) throws -> Set<String> {
        guard let data = try metadata.data(
            forKey: CloudKitSyncStateKeys.knownRecords,
            documentName: documentName
        ) else {
            return []
        }
        return try JSONDecoder().decode(Set<String>.self, from: data)
    }
}

private func insert(_ string: String, into doc: YDoc) throws {
    let text = try doc.text(named: "body")
    try doc.write { try $0.insert(string, into: text, at: 0) }
}

private func text(_ doc: YDoc) throws -> String {
    let text = try doc.text(named: "body")
    return try doc.read { try $0.string(from: text) }
}

/// An incremental record authored by some other device for `documentName`.
private func remoteRecord(
    _ contents: String,
    documentName: String,
    clientID: UInt64,
    codec: CloudKitRecordCodec
) throws -> CKRecord {
    let other = YDoc(clientID: clientID)
    try insert(contents, into: other)
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
func recordsOfEveryDocumentLandInTheOneZoneNamedAtConstruction() async throws {
    let vault = try await Vault.make(zoneName: "vault-a")
    let (pageA, docA) = try vault.page("a", clientID: 1)
    let (pageB, docB) = try vault.page("b", clientID: 2)
    try await pageA.start()
    try await pageB.start()
    defer {
        Task { await pageA.destroy() }
        Task { await pageB.destroy() }
    }

    try insert("alpha", into: docA)
    try insert("beta", into: docB)
    try await pageA.flush()
    try await pageB.flush()

    let recordIDs = await vault.engine.serverRecordIDs
    #expect(recordIDs.count == 2)
    #expect(recordIDs.allSatisfy { $0.zoneID == vault.codec.zoneID })
    let documents = Set(recordIDs.compactMap { try? vault.codec.documentName(fromRecordName: $0.recordName) })
    #expect(documents == ["a", "b"])
}

@Test
func recordToSaveIsAnsweredByTheOwningDocumentsProvider() async throws {
    let vault = try await Vault.make()
    let (pageA, docA) = try vault.page("a", clientID: 1)
    let (pageB, docB) = try vault.page("b", clientID: 2)
    try await pageA.start()
    try await pageB.start()
    defer {
        Task { await pageA.destroy() }
        Task { await pageB.destroy() }
    }

    try insert("alpha", into: docA)
    try insert("beta", into: docB)
    try await pageA.flush()
    try await pageB.flush()

    for recordID in await vault.engine.serverRecordIDs {
        let record = try #require(await vault.engine.serverRecord(for: recordID))
        let payload = try vault.codec.decodeIncremental(record)
        // The bytes came from the provider that owns the name's document.
        #expect(payload.documentName == (try vault.codec.documentName(fromRecordName: recordID.recordName)))
        #expect(payload.clientID == (payload.documentName == "a" ? 1 : 2))
    }
}

@Test
func oneFetchedBatchIsSplitBetweenTheDocumentsItTouches() async throws {
    let vault = try await Vault.make()
    let (pageA, docA) = try vault.page("a", clientID: 1)
    let (pageB, docB) = try vault.page("b", clientID: 2)
    try await pageA.start()
    try await pageB.start()
    defer {
        Task { await pageA.destroy() }
        Task { await pageB.destroy() }
    }

    // One batch, interleaved: two records for `a`, one for `b`.
    await vault.engine.simulateRemoteModification(
        try remoteRecord("A1", documentName: "a", clientID: 10, codec: vault.codec)
    )
    await vault.engine.simulateRemoteModification(
        try remoteRecord("B1", documentName: "b", clientID: 11, codec: vault.codec)
    )
    await vault.engine.simulateRemoteModification(
        try remoteRecord("A2", documentName: "a", clientID: 12, codec: vault.codec)
    )

    try await pageA.fetch()

    #expect(try text(docA).contains("A1"))
    #expect(try text(docA).contains("A2"))
    #expect(try !text(docA).contains("B1"))
    #expect(try text(docB) == "B1")
}

@Test
func aDeletedRecordIsRoutedByItsNameAlone() async throws {
    let vault = try await Vault.make()
    let (pageA, docA) = try vault.page("a", clientID: 1)
    let (pageB, docB) = try vault.page("b", clientID: 2)
    try await pageA.start()
    try await pageB.start()
    defer {
        Task { await pageA.destroy() }
        Task { await pageB.destroy() }
    }

    try insert("alpha", into: docA)
    try insert("beta", into: docB)
    try await pageA.flush()
    try await pageB.flush()

    let deletedID = vault.codec.incrementalRecordID(
        try vault.codec.documentKey("a"),
        clientID: 1,
        fromClock: 0,
        toClock: try docA.clientClock(clientID: 1)
    )
    #expect(try vault.knownRecordNames(forDocument: "a") == [deletedID.recordName])

    // A deletion carries no fields — only the record ID.
    await vault.engine.simulateRemoteDeletion(deletedID)
    try await pageA.fetch()

    #expect(try vault.knownRecordNames(forDocument: "a").isEmpty)
    #expect(try vault.knownRecordNames(forDocument: "b").count == 1)
}

@Test
func anUnparseableRecordNameSurfacesAnErrorInsteadOfRoutingToAnotherDocument() async throws {
    let vault = try await Vault.make()
    let (pageA, docA) = try vault.page("a", clientID: 1)
    try await pageA.start()
    defer { Task { await pageA.destroy() } }

    var errors = vault.store.errors.makeAsyncIterator()

    let wellFormed = try remoteRecord("A1", documentName: "a", clientID: 10, codec: vault.codec)
    let forged = CKRecord(
        recordType: CloudKitRecordType.incremental,
        recordID: CKRecord.ID(recordName: "not-a-document-scoped-name", zoneID: vault.codec.zoneID)
    )
    for key in wellFormed.allKeys() {
        forged[key] = wellFormed[key]
    }
    await vault.engine.simulateRemoteModification(forged)

    try await pageA.fetch()

    #expect(try text(docA).isEmpty)
    let error = await errors.next()
    #expect(error as? CloudKitRecordCodecError == .malformedRecordName("not-a-document-scoped-name"))
}

@Test
func aRecordWhoseNameAndDocumentFieldDisagreeReachesNeitherDocument() async throws {
    let vault = try await Vault.make()
    let (pageA, docA) = try vault.page("a", clientID: 1)
    let (pageB, docB) = try vault.page("b", clientID: 2)
    try await pageA.start()
    try await pageB.start()
    defer {
        Task { await pageA.destroy() }
        Task { await pageB.destroy() }
    }

    var errors = vault.store.errors.makeAsyncIterator()

    // Named for `a`, but the field claims `b`.
    let record = try remoteRecord("forged", documentName: "a", clientID: 10, codec: vault.codec)
    record[CloudKitRecordField.documentName] = "b" as NSString
    await vault.engine.simulateRemoteModification(record)

    try await pageA.fetch()

    #expect(try text(docA).isEmpty)
    #expect(try text(docB).isEmpty)
    let error = await errors.next()
    #expect(error as? CloudKitRecordCodecError == .documentNameMismatch(recordName: "a", field: "b"))
}

@Test
func oneSentBatchIsSplitBetweenTheDocumentsItTouches() async throws {
    let vault = try await Vault.make()
    let (pageA, docA) = try vault.page("a", clientID: 1)
    let (pageB, docB) = try vault.page("b", clientID: 2)
    try await pageA.start()
    try await pageB.start()
    defer {
        Task { await pageA.destroy() }
        Task { await pageB.destroy() }
    }

    // Queue both documents' writes, then send them in ONE batch, so the store
    // has to split a mixed `sentChanges` event rather than two clean ones.
    try insert("alpha", into: docA)
    try insert("beta", into: docB)
    async let flushA: Void = pageA.flush()
    async let flushB: Void = pageB.flush()
    _ = try await (flushA, flushB)

    // Each provider marked its own write confirmed, so neither re-uploads.
    #expect(await vault.engine.serverRecordIDs.count == 2)
    try await pageA.flush()
    try await pageB.flush()
    #expect(await vault.engine.serverRecordIDs.count == 2)

    #expect(try vault.knownRecordNames(forDocument: "a").count == 1)
    #expect(try vault.knownRecordNames(forDocument: "b").count == 1)
}

@Test
func aRecordFromAnotherStoresZoneIsNotRouted() async throws {
    let vault = try await Vault.make(zoneName: "vault-a")
    let neighbour = try await Vault.make(zoneName: "vault-b")
    #expect(vault.codec.zoneID != neighbour.codec.zoneID)

    let (pageA, docA) = try vault.page("a", clientID: 1)
    try await pageA.start()
    defer { Task { await pageA.destroy() } }

    var errors = vault.store.errors.makeAsyncIterator()

    // A record built for the neighbouring store's zone arrives here.
    let foreign = try remoteRecord("elsewhere", documentName: "a", clientID: 10, codec: neighbour.codec)
    await vault.engine.simulateRemoteModification(foreign)

    try await pageA.fetch()

    #expect(try text(docA).isEmpty)
    #expect(await errors.next() is CloudKitRoutingError)
}

@Test
func removingOneDocumentLeavesTheOtherUntouched() async throws {
    let vault = try await Vault.make()
    let (pageA, docA) = try vault.page("a", clientID: 1)
    let (pageB, docB) = try vault.page("b", clientID: 2)
    try await pageA.start()
    try await pageB.start()
    defer { Task { await pageB.destroy() } }

    try insert("alpha", into: docA)
    try insert("beta", into: docB)
    try await pageA.flush()
    try await pageB.flush()
    #expect(await vault.engine.serverRecordIDs.count == 2)

    await pageA.destroy()
    try await vault.store.removeDocument(named: "a")

    let remaining = await vault.engine.serverRecordIDs
    #expect(remaining.count == 1)
    #expect(try vault.codec.documentName(fromRecordName: remaining[0].recordName) == "b")

    // `a`'s local state is gone; `b` keeps its drain set and registry.
    #expect(try vault.knownRecordNames(forDocument: "a").isEmpty)
    #expect(try vault.metadata.data(forKey: CloudKitSyncStateKeys.drainSet, documentName: "a") == nil)
    #expect(try vault.knownRecordNames(forDocument: "b").count == 1)
    #expect(try vault.metadata.data(forKey: CloudKitSyncStateKeys.drainSet, documentName: "b") != nil)

    // `b` still syncs.
    try insert("more", into: docB)
    try await pageB.flush()
    #expect(await vault.engine.serverRecordIDs.count == 2)
}

@Test
func removingTheZoneDeletesEveryDocumentAndLeavesNothingToSync() async throws {
    let vault = try await Vault.make()
    let (pageA, docA) = try vault.page("a", clientID: 1)
    let (pageB, docB) = try vault.page("b", clientID: 2)
    try await pageA.start()
    try await pageB.start()

    try insert("alpha", into: docA)
    try insert("beta", into: docB)
    try await pageA.flush()
    try await pageB.flush()

    await pageA.destroy()
    await pageB.destroy()
    try await vault.store.removeZone()

    #expect(await vault.engine.serverRecordIDs.isEmpty)
    #expect(try vault.knownRecordNames(forDocument: "a").isEmpty)
    #expect(try vault.knownRecordNames(forDocument: "b").isEmpty)
    #expect(try vault.metadata.data(forKey: CloudKitSyncStateKeys.drainSet, documentName: "a") == nil)
    #expect(try vault.metadata.data(forKey: CloudKitSyncStateKeys.drainSet, documentName: "b") == nil)

    // A later start on the same metadata syncs nothing back.
    let restarted = try await Vault.make(directory: vault.directory)
    let (pageC, docC) = try restarted.page("a", clientID: 3)
    try await pageC.start()
    defer { Task { await pageC.destroy() } }
    try await pageC.fetch()
    #expect(try text(docC).isEmpty)
}

@Test
func removingTheZoneClearsStateForADocumentThatNeverWroteARecord() async throws {
    let vault = try await Vault.make()
    // A provider that starts and never flushes still has a drain set.
    let (page, _) = try vault.page("quiet", clientID: 1)
    try await page.start()
    #expect(try vault.metadata.data(forKey: CloudKitSyncStateKeys.drainSet, documentName: "quiet") != nil)
    #expect(try vault.knownRecordNames(forDocument: "quiet").isEmpty)

    await page.destroy()
    try await vault.store.removeZone()

    #expect(try vault.metadata.data(forKey: CloudKitSyncStateKeys.drainSet, documentName: "quiet") == nil)
}

@Test
func removingTheZoneRejectsAnyAttachedProvider() async throws {
    let vault = try await Vault.make()
    let (pageA, _) = try vault.page("a", clientID: 1)
    try await pageA.start()
    defer { Task { await pageA.destroy() } }

    await #expect(throws: CloudKitProviderError.activeProvider(documentName: "a")) {
        try await vault.store.removeZone()
    }
}
#endif
