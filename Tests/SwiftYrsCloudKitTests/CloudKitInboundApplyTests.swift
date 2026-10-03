#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs
@testable import SwiftYrsCloudKit
import SwiftYrsTestSupport
import Testing

private struct Device {
    let engine: MockCloudKitSyncEngine
    let store: CloudKitSyncStore
    let codec: CloudKitRecordCodec
    let provider: CloudKitProvider
    let doc: YDoc

    static func make(
        documentName: String, clientID: UInt64, maxTransactionRetries: Int = 8,
        testHooks: CloudKitProvider.TestHooks = .none
    ) async throws -> Device {
        let engine = MockCloudKitSyncEngine()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftyrs-ck-inbound-\(UUID().uuidString)")
        let codec = try CloudKitRecordCodec(zoneName: "test-zone", assetDirectory: dir)
        let metadata = FileCloudKitMetadataStore(directory: dir.appendingPathComponent("meta"))
        let store = CloudKitSyncStore(adapter: engine, codec: codec, metadataStore: metadata)
        await store.start()
        let doc = YDoc(clientID: clientID)
        let provider = try CloudKitProvider(
            documentName: documentName,
            doc: doc,
            store: store,
            options: CloudKitProviderOptions(debounce: .seconds(600), maxTransactionRetries: maxTransactionRetries),
            testHooks: testHooks
        )
        return Device(engine: engine, store: store, codec: codec, provider: provider, doc: doc)
    }
}

private func text(_ doc: YDoc) throws -> String {
    let text = try doc.text(named: "body")
    return try doc.read { try $0.string(from: text) }
}

private func insert(_ string: String, at index: UInt32, into doc: YDoc) throws {
    let text = try doc.text(named: "body")
    try doc.write { try $0.insert(string, into: text, at: index) }
}

/// Pipe every record one device's engine holds into another device's fetch queue.
private func deliver(from source: Device, to destination: Device) async {
    for recordID in await source.engine.serverRecordIDs {
        if let record = await source.engine.serverRecord(for: recordID) {
            await destination.engine.simulateRemoteModification(record)
        }
    }
}

@Test
func remoteRecordsAreAppliedToTheDoc() async throws {
    let device = try await Device.make(documentName: "doc", clientID: 1)
    try await device.provider.start()
    defer { Task { await device.provider.destroy() } }

    // A record authored by another writer (clientID 2) arrives from CloudKit.
    let other = YDoc(clientID: 2)
    try insert("remote", at: 0, into: other)
    let payload = CloudKitIncrementalRecordPayload(
        documentName: "doc",
        clientID: 2,
        fromClock: 0,
        toClock: try other.clientClock(clientID: 2),
        update: try other.encodeClientStateAsUpdateV1(clientID: 2, fromClock: 0)
    )
    let record = try device.codec.encodeIncremental(payload)
    await device.engine.simulateRemoteModification(record)

    try await device.provider.fetch()

    #expect(try text(device.doc) == "remote")
}

@Test
func twoDevicesConvergeThroughPairedMocks() async throws {
    let a = try await Device.make(documentName: "doc", clientID: 1)
    let b = try await Device.make(documentName: "doc", clientID: 2)
    try await a.provider.start()
    try await b.provider.start()
    defer { Task { await a.provider.destroy(); await b.provider.destroy() } }

    try insert("A", at: 0, into: a.doc)
    try await a.provider.flush()
    try insert("B", at: 0, into: b.doc)
    try await b.provider.flush()

    // Exchange each device's records and apply.
    await deliver(from: a, to: b)
    await deliver(from: b, to: a)
    try await a.provider.fetch()
    try await b.provider.fetch()

    // Both docs hold both writers' inserts and agree byte-for-byte.
    #expect(try text(a.doc) == text(b.doc))
    #expect(try text(a.doc).contains("A"))
    #expect(try text(a.doc).contains("B"))
}

@Test
func applyingRemoteUpdateDoesNotReUploadIt() async throws {
    let device = try await Device.make(documentName: "doc", clientID: 1)
    try await device.provider.start()
    defer { Task { await device.provider.destroy() } }

    // Apply a remote record from writer 2; this device authored nothing.
    let other = YDoc(clientID: 2)
    try insert("remote", at: 0, into: other)
    let record = try device.codec.encodeIncremental(
        CloudKitIncrementalRecordPayload(
            documentName: "doc",
            clientID: 2,
            fromClock: 0,
            toClock: try other.clientClock(clientID: 2),
            update: try other.encodeClientStateAsUpdateV1(clientID: 2, fromClock: 0)
        )
    )
    await device.engine.simulateRemoteModification(record)
    try await device.provider.fetch()

    // A flush after the apply ships nothing new: client-scoped capture for our
    // own clientID is empty, so the applied remote update is not echoed back.
    let before = Set(await device.engine.serverRecordIDs)
    try await device.provider.flush()
    let after = Set(await device.engine.serverRecordIDs)
    #expect(after == before) // no echo record added
    #expect(await device.engine.pendingSaveIDs.isEmpty)
}

@Test
func applyRetriesPastAConcurrentWriteTransaction() async throws {
    let gate = TestThreadGate()
    defer { gate.open() }
    let finished = AsyncStream.makeStream(of: Void.self)
    let device = try await Device.make(
        documentName: "doc", clientID: 1, maxTransactionRetries: 200,
        testHooks: .init(onTransactionConflict: {
            gate.open()
            _ = try? await nextTestEvent(finished.stream)
        })
    )
    try await device.provider.start()
    defer { Task { await device.provider.destroy() } }

    let other = YDoc(clientID: 2)
    try insert("remote", at: 0, into: other)
    let record = try device.codec.encodeIncremental(
        CloudKitIncrementalRecordPayload(
            documentName: "doc",
            clientID: 2,
            fromClock: 0,
            toClock: try other.clientClock(clientID: 2),
            update: try other.encodeClientStateAsUpdateV1(clientID: 2, fromClock: 0)
        )
    )
    await device.engine.simulateRemoteModification(record)

    // Hold a write transaction open while the fetch applies; the apply must
    // retry past the transactionConflict.
    let holder = Task {
        try await onTestThread {
            defer { finished.continuation.yield(()); finished.continuation.finish() }
            let localText = try device.doc.text(named: "body")
            try device.doc.write { transaction in
                try transaction.insert("local", into: localText, at: 0)
                gate.enterAndWait()
            }
        }
    }
    try await gate.waitForEntry()
    try await device.provider.fetch()
    try await holder.value

    #expect(try text(device.doc).contains("remote"))
    #expect(try text(device.doc).contains("local"))
}

@Test
func applyIsIdempotentWhenSameRecordArrivesTwice() async throws {
    let device = try await Device.make(documentName: "doc", clientID: 1)
    try await device.provider.start()
    defer { Task { await device.provider.destroy() } }

    let other = YDoc(clientID: 2)
    try insert("once", at: 0, into: other)
    let record = try device.codec.encodeIncremental(
        CloudKitIncrementalRecordPayload(
            documentName: "doc",
            clientID: 2,
            fromClock: 0,
            toClock: try other.clientClock(clientID: 2),
            update: try other.encodeClientStateAsUpdateV1(clientID: 2, fromClock: 0)
        )
    )

    await device.engine.simulateRemoteModification(record)
    try await device.provider.fetch()
    await device.engine.simulateRemoteModification(record)
    try await device.provider.fetch()

    #expect(try text(device.doc) == "once")
}
#endif
