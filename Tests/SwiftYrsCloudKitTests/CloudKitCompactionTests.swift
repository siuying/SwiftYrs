#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import Testing

private struct CompactionHarness {
    let engine: MockCloudKitSyncEngine
    let store: CloudKitSyncStore
    let codec: CloudKitRecordCodec

    static func make() async -> CompactionHarness {
        let engine = MockCloudKitSyncEngine()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftyrs-ck-compaction-\(UUID().uuidString)")
        let codec = CloudKitRecordCodec(assetDirectory: dir.appendingPathComponent("assets"))
        let metadata = FileCloudKitMetadataStore(directory: dir.appendingPathComponent("meta"))
        let store = CloudKitSyncStore(adapter: engine, codec: codec, metadataStore: metadata)
        await store.start()
        return CompactionHarness(engine: engine, store: store, codec: codec)
    }

    func provider(
        clientID: UInt64,
        options: CloudKitProviderOptions
    ) -> (CloudKitProvider, YDoc) {
        let doc = YDoc(clientID: clientID)
        let provider = CloudKitProvider(documentName: "doc", doc: doc, store: store, options: options)
        return (provider, doc)
    }
}

private func compactAfterFirstIncremental(jitter: @escaping @Sendable () -> Double = { 0 }) -> CloudKitProviderOptions {
    CloudKitProviderOptions(
        debounce: .seconds(600),
        compaction: CompactionPolicy(incrementalCountThreshold: 1, incrementalByteThreshold: .max, jitterFraction: 0),
        jitter: jitter
    )
}

private func neverAutoCompact() -> CloudKitProviderOptions {
    CloudKitProviderOptions(
        debounce: .seconds(600),
        compaction: CompactionPolicy(incrementalCountThreshold: .max, incrementalByteThreshold: .max),
        jitter: { 0 }
    )
}

private func insert(_ string: String, at index: UInt32 = 0, into doc: YDoc) throws {
    let text = try doc.text(named: "body")
    try doc.write { try $0.insert(string, into: text, at: index) }
}

private func bodyText(_ doc: YDoc) throws -> String {
    let text = try doc.text(named: "body")
    return try doc.read { try $0.string(from: text) }
}

@Test
func thresholdTripsCompactionWritingSnapshotAndGCingSubsumedIncremental() async throws {
    let h = await CompactionHarness.make()
    let (provider, doc) = h.provider(clientID: 7, options: compactAfterFirstIncremental())
    try await provider.start()
    defer { Task { await provider.destroy() } }

    try insert("hello", into: doc)
    let incrementalID = h.codec.incrementalRecordID(
        documentName: "doc", clientID: 7, fromClock: 0, toClock: try doc.clientClock(clientID: 7)
    )
    try await provider.flush()

    // The full-state snapshot was written with a stored state vector...
    let snapshotID = h.codec.snapshotRecordID(documentName: "doc")
    let snapshotRecord = try #require(await h.engine.serverRecord(for: snapshotID))
    let snapshot = try h.codec.decodeSnapshot(snapshotRecord)
    #expect(!snapshot.stateVector.data.isEmpty)
    let fresh = YDoc()
    try fresh.apply(snapshot.update)
    #expect(try bodyText(fresh) == "hello") // full state, not a diff

    // ...and the subsumed incremental was GC'd.
    #expect(await h.engine.serverRecord(for: incrementalID) == nil)
}

@Test
func incrementalAuthoredAfterSnapshotIsRetained() async throws {
    let h = await CompactionHarness.make()
    let (provider, doc) = h.provider(clientID: 7, options: neverAutoCompact())
    try await provider.start()
    defer { Task { await provider.destroy() } }

    try insert("a", into: doc)
    try await provider.flush()
    await provider.compact() // snapshot covers clock through "a"; that incremental GC'd

    // A new edit after the snapshot.
    try insert("b", into: doc)
    let secondID = h.codec.incrementalRecordID(
        documentName: "doc", clientID: 7, fromClock: try doc.clientClock(clientID: 7) - 1,
        toClock: try doc.clientClock(clientID: 7)
    )
    try await provider.flush()

    // The post-snapshot incremental is retained (no compaction ran for it).
    #expect(await h.engine.serverRecord(for: secondID) != nil)
    #expect(await h.engine.serverRecord(for: h.codec.snapshotRecordID(documentName: "doc")) != nil)
}

@Test
func subsumedIncrementalIsNotDeletedUntilSnapshotIsConfirmed() async throws {
    let h = await CompactionHarness.make()
    // Only one snapshot attempt: a seeded conflict means it never confirms.
    let options = CloudKitProviderOptions(
        debounce: .seconds(600),
        compaction: CompactionPolicy(incrementalCountThreshold: 1, incrementalByteThreshold: .max, jitterFraction: 0),
        jitter: { 0 },
        maxSnapshotRetries: 1
    )
    let (provider, doc) = h.provider(clientID: 7, options: options)
    try await provider.start()
    defer { Task { await provider.destroy() } }

    let serverSnapshot = try h.codec.encodeSnapshot(
        CloudKitSnapshotRecordPayload(
            documentName: "doc",
            update: try YDoc().encodeStateAsUpdateV1(),
            stateVector: try YDoc().stateVector()
        )
    )
    await h.engine.seedConflict(for: h.codec.snapshotRecordID(documentName: "doc"), serverRecord: serverSnapshot)

    try insert("hello", into: doc)
    let incrementalID = h.codec.incrementalRecordID(
        documentName: "doc", clientID: 7, fromClock: 0, toClock: try doc.clientClock(clientID: 7)
    )
    try await provider.flush() // compaction attempt conflicts and gives up

    // Snapshot never confirmed → the incremental must NOT be GC'd.
    #expect(await h.engine.serverRecord(for: incrementalID) != nil)
}

@Test
func serverRecordChangedMergesAndConverges() async throws {
    let h = await CompactionHarness.make()
    let (provider, doc) = h.provider(clientID: 7, options: neverAutoCompact())
    try await provider.start()
    defer { Task { await provider.destroy() } }

    try insert("local", into: doc)
    try await provider.flush()

    // The server already holds a snapshot with another device's content.
    let serverDoc = YDoc(clientID: 99)
    try insert("server", into: serverDoc)
    let serverSnapshot = try h.codec.encodeSnapshot(
        CloudKitSnapshotRecordPayload(
            documentName: "doc",
            update: try serverDoc.encodeStateAsUpdateV1(),
            stateVector: try serverDoc.stateVector()
        )
    )
    await h.engine.seedConflict(for: h.codec.snapshotRecordID(documentName: "doc"), serverRecord: serverSnapshot)

    await provider.compact()

    // Merge-on-conflict applied the server snapshot (lossless), so the doc now
    // holds both writers' content and the merged snapshot is saved.
    #expect(try bodyText(doc).contains("local"))
    #expect(try bodyText(doc).contains("server"))
    let savedSnapshot = try #require(await h.engine.serverRecord(for: h.codec.snapshotRecordID(documentName: "doc")))
    let merged = try h.codec.decodeSnapshot(savedSnapshot)
    let check = YDoc()
    try check.apply(merged.update)
    #expect(try bodyText(check).contains("local"))
    #expect(try bodyText(check).contains("server"))
}

@Test
func jitterDelaysCompactionToStaggerTheHerd() async throws {
    let h = await CompactionHarness.make()
    // Threshold 1, but fully-jittered effective threshold is 2.
    let options = CloudKitProviderOptions(
        debounce: .seconds(600),
        compaction: CompactionPolicy(incrementalCountThreshold: 1, incrementalByteThreshold: .max, jitterFraction: 1.0),
        jitter: { 1.0 }
    )
    let (provider, doc) = h.provider(clientID: 7, options: options)
    try await provider.start()
    defer { Task { await provider.destroy() } }

    let snapshotID = h.codec.snapshotRecordID(documentName: "doc")

    try insert("a", into: doc)
    try await provider.flush()
    #expect(await h.engine.serverRecord(for: snapshotID) == nil) // jitter held it off

    try insert("b", into: doc)
    try await provider.flush()
    #expect(await h.engine.serverRecord(for: snapshotID) != nil) // backlog now crosses the jittered threshold
}
#endif
