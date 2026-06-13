#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import Testing

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private struct Harness {
    let engine: MockCloudKitSyncEngine
    let store: CloudKitSyncStore
    let codec: CloudKitRecordCodec

    static func make() async -> Harness {
        let engine = MockCloudKitSyncEngine()
        let assetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftyrs-cloudkit-tests-\(UUID().uuidString)")
        let codec = CloudKitRecordCodec(assetDirectory: assetDir)
        let metadata = FileCloudKitMetadataStore(directory: assetDir.appendingPathComponent("meta"))
        let store = CloudKitSyncStore(adapter: engine, codec: codec, metadataStore: metadata)
        await store.start()
        return Harness(engine: engine, store: store, codec: codec)
    }
}

private func makeProvider(
    _ harness: Harness,
    documentName: String = "doc",
    clientID: UInt64 = 7,
    debounce: Duration = .milliseconds(20)
) -> (CloudKitProvider, YDoc) {
    let doc = YDoc(clientID: clientID)
    let provider = CloudKitProvider(
        documentName: documentName,
        doc: doc,
        store: harness.store,
        options: CloudKitProviderOptions(debounce: debounce)
    )
    return (provider, doc)
}

private func insert(_ string: String, into doc: YDoc) throws {
    let text = try doc.text(named: "body")
    try doc.write { try $0.insert(string, into: text, at: 0) }
}

@discardableResult
private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @escaping () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@Test
func docEditEnqueuesIncrementalRecordAfterDebounce() async throws {
    let harness = await Harness.make()
    let (provider, doc) = makeProvider(harness)
    try await provider.start()
    defer { Task { await provider.destroy() } }

    try insert("hello", into: doc)

    let saved = await waitUntil { await !harness.engine.serverRecordIDs.isEmpty }
    #expect(saved)

    let recordID = harness.codec.incrementalRecordID(
        documentName: "doc",
        clientID: 7,
        fromClock: 0,
        toClock: try doc.clientClock(clientID: 7)
    )
    let record = try #require(await harness.engine.serverRecord(for: recordID))
    let payload = try harness.codec.decodeIncremental(record)
    #expect(payload.clientID == 7)
    #expect(payload.fromClock == 0)

    // The enqueued diff converges a fresh doc.
    let fresh = YDoc()
    let text = try fresh.text(named: "body")
    try fresh.apply(payload.update)
    try fresh.read { try #expect($0.string(from: text) == "hello") }
}

@Test
func manualFlushCapturesWithoutWaitingForDebounce() async throws {
    let harness = await Harness.make()
    let (provider, doc) = makeProvider(harness, debounce: .seconds(600))
    try await provider.start()
    defer { Task { await provider.destroy() } }

    try insert("hi", into: doc)
    try await provider.flush()

    #expect(await !harness.engine.serverRecordIDs.isEmpty)
}

@Test
func backgroundFlushCapturesPendingEdits() async throws {
    let harness = await Harness.make()
    let (provider, doc) = makeProvider(harness, debounce: .seconds(600))
    try await provider.start()
    defer { Task { await provider.destroy() } }

    try insert("bg", into: doc)
    try await provider.flushForBackground()

    #expect(await !harness.engine.serverRecordIDs.isEmpty)
}

@Test
func markerAdvancesSoSecondFlushShipsOnlyNewEdits() async throws {
    let harness = await Harness.make()
    let (provider, doc) = makeProvider(harness, debounce: .seconds(600))
    try await provider.start()
    defer { Task { await provider.destroy() } }

    try insert("one", into: doc)
    try await provider.flush()
    let afterFirst = try doc.clientClock(clientID: 7)

    let text = try doc.text(named: "body")
    try doc.write { try $0.insert("two", into: text, at: 0) }
    try await provider.flush()

    // The second incremental starts where the first left off (no re-ship).
    let secondID = harness.codec.incrementalRecordID(
        documentName: "doc",
        clientID: 7,
        fromClock: afterFirst,
        toClock: try doc.clientClock(clientID: 7)
    )
    #expect(await harness.engine.serverRecord(for: secondID) != nil)
}

@Test
func syncedStreamEmitsOnStartAndAfterFlush() async throws {
    let harness = await Harness.make()
    let (provider, doc) = makeProvider(harness, debounce: .seconds(600))

    var iterator = provider.synced.makeAsyncIterator()
    try await provider.start()
    #expect(await iterator.next() == true) // start

    try insert("x", into: doc)
    try await provider.flush()
    #expect(await iterator.next() == true) // after a successful send

    await provider.destroy()
}

@Test
func errorsStreamEmitsOnSendFailure() async throws {
    let harness = await Harness.make()
    let (provider, doc) = makeProvider(harness, debounce: .seconds(600))
    try await provider.start()
    defer { Task { await provider.destroy() } }

    try insert("z", into: doc)
    let recordID = harness.codec.incrementalRecordID(
        documentName: "doc",
        clientID: 7,
        fromClock: 0,
        toClock: try doc.clientClock(clientID: 7)
    )
    let serverSide = CKRecord(recordType: CloudKitRecordType.incremental, recordID: recordID)
    await harness.engine.seedConflict(for: recordID, serverRecord: serverSide)

    var iterator = provider.errors.makeAsyncIterator()
    try await provider.flush()

    let error = await iterator.next()
    #expect(error as? CloudKitSendError == .serverRecordChanged)
}

@Test
func concurrentAppWriteResolvesViaRetry() async throws {
    let harness = await Harness.make()
    let doc = YDoc(clientID: 7)
    // Generous retry budget so the capture reliably outlasts the held write.
    let provider = CloudKitProvider(
        documentName: "doc",
        doc: doc,
        store: harness.store,
        options: CloudKitProviderOptions(debounce: .seconds(600), maxTransactionRetries: 200)
    )
    try await provider.start()
    defer { Task { await provider.destroy() } }

    try insert("seed", into: doc)

    // Hold a write transaction open on another thread, then flush — the capture
    // must retry past the transactionConflict until the writer releases.
    let text = try doc.text(named: "body")
    let acquired = Flag()
    let holder = Task.detached {
        try doc.write { transaction in
            try transaction.insert("!", into: text, at: 0)
            acquired.set()
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    while !acquired.get() { try? await Task.sleep(for: .milliseconds(1)) }
    try await provider.flush()
    try await holder.value

    #expect(await !harness.engine.serverRecordIDs.isEmpty)
}

@Test
func destroyStopsIngressSoLaterEditsDoNotEnqueue() async throws {
    let harness = await Harness.make()
    let (provider, doc) = makeProvider(harness, debounce: .milliseconds(20))
    try await provider.start()

    await provider.destroy()

    try insert("after", into: doc)
    // Give the (now-cancelled) debounce well past its window.
    try? await Task.sleep(for: .milliseconds(80))
    #expect(await harness.engine.serverRecordIDs.isEmpty)
}

@Test
func duplicateProviderForSameDocumentIsRejected() async throws {
    let harness = await Harness.make()
    let (first, _) = makeProvider(harness, documentName: "dup")
    let (second, _) = makeProvider(harness, documentName: "dup")
    try await first.start()
    defer { Task { await first.destroy() } }

    await #expect(throws: CloudKitProviderError.duplicateProvider(documentName: "dup")) {
        try await second.start()
    }
}
#endif
