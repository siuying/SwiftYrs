#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import Testing

/// A persistent "device": a fixed metadata/asset directory reused across
/// process restarts, with a fresh engine + store each launch.
private struct Device {
    let dir: URL
    let metadata: FileCloudKitMetadataStore
    let codec: CloudKitRecordCodec

    static func make() -> Device {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftyrs-ck-recovery-\(UUID().uuidString)")
        return Device(
            dir: dir,
            metadata: FileCloudKitMetadataStore(directory: dir.appendingPathComponent("meta")),
            codec: CloudKitRecordCodec(assetDirectory: dir.appendingPathComponent("assets"))
        )
    }

    /// A fresh engine + store sharing this device's persisted metadata.
    func boot() async -> (MockCloudKitSyncEngine, CloudKitSyncStore) {
        let engine = MockCloudKitSyncEngine()
        let store = CloudKitSyncStore(adapter: engine, codec: codec, metadataStore: metadata)
        await store.start()
        return (engine, store)
    }

    func persistedDrainSet() throws -> [String: UInt32] {
        guard let data = try metadata.data(
            forKey: CloudKitSyncStateKeys.drainSet,
            documentName: "doc"
        ) else { return [:] }
        return try JSONDecoder().decode([String: UInt32].self, from: data)
    }

    func seedDrainSet(_ entries: [UInt64: UInt32]) throws {
        let stringKeyed = Dictionary(uniqueKeysWithValues: entries.map { (String($0.key), $0.value) })
        let data = try JSONEncoder().encode(stringKeyed)
        try metadata.set(data, forKey: CloudKitSyncStateKeys.drainSet, documentName: "doc")
    }
}

private func makeDoc(clientID: UInt64, seededFrom seed: YDoc? = nil) throws -> YDoc {
    let doc = YDoc(clientID: clientID)
    if let seed {
        try doc.apply(try seed.encodeStateAsUpdateV1())
    }
    return doc
}

private func insert(_ string: String, into doc: YDoc) throws {
    let text = try doc.text(named: "body")
    try doc.write { try $0.insert(string, into: text, at: 0) }
}

@Test
func restartDrainsAnUnconfirmedSessionAndRetiresIt() async throws {
    let device = Device.make()

    // Session 1 crashes after writing but before its edits upload.
    let (_, store1) = await device.boot()
    let doc1 = try makeDoc(clientID: 11)
    let provider1 = CloudKitProvider(
        documentName: "doc", doc: doc1, store: store1,
        options: CloudKitProviderOptions(debounce: .seconds(600))
    )
    try await provider1.start()
    try insert("hello", into: doc1) // not flushed → not uploaded
    await provider1.destroy()

    #expect(try device.persistedDrainSet().keys.contains("11"))

    // Session 2 relaunches: the doc is reconstructed (as SQLiteProvider would),
    // and recovery re-ships session 1's outstanding diff.
    let (engine2, store2) = await device.boot()
    let doc2 = try makeDoc(clientID: 22, seededFrom: doc1)
    let provider2 = CloudKitProvider(
        documentName: "doc", doc: doc2, store: store2,
        options: CloudKitProviderOptions(debounce: .seconds(600))
    )
    try await provider2.start()
    defer { Task { await provider2.destroy() } }

    // Session 1's incremental was recovered and uploaded.
    let recordID = device.codec.incrementalRecordID(
        documentName: "doc", clientID: 11, fromClock: 0,
        toClock: try doc2.clientClock(clientID: 11)
    )
    #expect(await engine2.serverRecord(for: recordID) != nil)

    // Session 11 is retired once fully drained; session 22 remains open.
    let drainSet = try device.persistedDrainSet()
    #expect(drainSet["11"] == nil)
    #expect(drainSet.keys.contains("22"))
}

@Test
func chainedCrashReSyncsAllOpenSessions() async throws {
    let device = Device.make()

    // Two prior sessions both left edits in the doc but never confirmed upload.
    let seed = try makeDoc(clientID: 11)
    try insert("aaa", into: seed)
    let writer33 = try makeDoc(clientID: 33)
    try insert("bbb", into: writer33)
    try seed.apply(try writer33.encodeStateAsUpdateV1())
    try device.seedDrainSet([11: 0, 33: 0])

    // Relaunch as a third session over the reconstructed doc.
    let (engine, store) = await device.boot()
    let doc = try makeDoc(clientID: 44, seededFrom: seed)
    let provider = CloudKitProvider(
        documentName: "doc", doc: doc, store: store,
        options: CloudKitProviderOptions(debounce: .seconds(600))
    )
    try await provider.start()
    defer { Task { await provider.destroy() } }

    // Both prior sessions' incrementals were re-shipped.
    let id11 = device.codec.incrementalRecordID(
        documentName: "doc", clientID: 11, fromClock: 0, toClock: try doc.clientClock(clientID: 11)
    )
    let id33 = device.codec.incrementalRecordID(
        documentName: "doc", clientID: 33, fromClock: 0, toClock: try doc.clientClock(clientID: 33)
    )
    #expect(await engine.serverRecord(for: id11) != nil)
    #expect(await engine.serverRecord(for: id33) != nil)

    let drainSet = try device.persistedDrainSet()
    #expect(drainSet["11"] == nil)
    #expect(drainSet["33"] == nil)
}

@Test
func engineStatePersistsAcrossRestartsAndAvoidsColdRefetch() async throws {
    let device = Device.make()

    // Session 1 flushes, so the engine emits a state serialization the store persists.
    let (engine1, store1) = await device.boot()
    #expect(await engine1.restoredState == nil) // first launch is cold
    let doc1 = try makeDoc(clientID: 11)
    let provider1 = CloudKitProvider(
        documentName: "doc", doc: doc1, store: store1,
        options: CloudKitProviderOptions(debounce: .seconds(600))
    )
    try await provider1.start()
    try insert("x", into: doc1)
    try await provider1.flush()
    await provider1.destroy()

    #expect(try device.metadata.data(
        forKey: CloudKitSyncStateKeys.engineState,
        documentName: CloudKitSyncStateKeys.storeNamespace
    ) != nil)

    // Session 2 restores the engine state on boot → no cold re-fetch.
    let (engine2, _) = await device.boot()
    #expect(await engine2.restoredState != nil)
}

@Test
func cleanSessionWithoutOutstandingEditsRecoversNothing() async throws {
    let device = Device.make()

    // Prior session that already uploaded everything: drain marker == doc clock.
    let seed = try makeDoc(clientID: 11)
    try insert("done", into: seed)
    try device.seedDrainSet([11: try seed.clientClock(clientID: 11)])

    let (engine, store) = await device.boot()
    let doc = try makeDoc(clientID: 22, seededFrom: seed)
    let provider = CloudKitProvider(
        documentName: "doc", doc: doc, store: store,
        options: CloudKitProviderOptions(debounce: .seconds(600))
    )
    try await provider.start()
    defer { Task { await provider.destroy() } }

    // Nothing outstanding → nothing re-shipped, and 11 is retired.
    #expect(await engine.serverRecordIDs.isEmpty)
    #expect(try device.persistedDrainSet()["11"] == nil)
}
#endif
