import Foundation
import SwiftYrsTestSupport
import Testing
@testable import SwiftYrs

private struct YjsSyncFixture: Decodable {
    let multiMessage: Data

    static func load(_ name: String) throws -> YjsSyncFixture {
        try loadFixture(name)
    }
}

@Test
func syncMessagesEncodeAndDecodeTypedPayloads() throws {
    let doc = YDoc(clientID: 1)
    let stateVector = try doc.stateVector()
    let update = try doc.encodeStateAsUpdateV1()
    let awareness = YAwareness(document: doc)
    try awareness.setLocalState(["name": "Ada"])
    let awarenessUpdate = try awareness.encodeUpdate()

    let messages: [YSyncMessage] = [
        try .syncStep1(stateVector),
        try .syncStep2(update),
        try .update(update),
        try .awareness(awarenessUpdate),
        try .awarenessQuery()
    ]

    let decoded = try YSyncMessage.decodePayload(YSyncMessage.joinedPayload(messages))

    #expect(decoded.count == 5)
    if case let .syncStep1(decodedStateVector, _) = decoded[0] {
        #expect(decodedStateVector == stateVector)
    } else {
        Issue.record("Expected sync step 1")
    }
    if case let .syncStep2(decodedUpdate, _) = decoded[1] {
        #expect(decodedUpdate == update)
    } else {
        Issue.record("Expected sync step 2")
    }
    if case let .update(decodedUpdate, _) = decoded[2] {
        #expect(decodedUpdate == update)
    } else {
        Issue.record("Expected update")
    }
    if case let .awareness(decodedAwareness, _) = decoded[3] {
        #expect(decodedAwareness == awarenessUpdate)
    } else {
        Issue.record("Expected awareness")
    }
    if case .awarenessQuery = decoded[4] {} else {
        Issue.record("Expected awareness query")
    }
}

@Test
func syncProtocolAppliesStepOneResponseToRemoteDocument() throws {
    let sourceDoc = YDoc(clientID: 1)
    let sourceText = try sourceDoc.text(named: "body")
    try sourceDoc.write { transaction in
        try transaction.insert("hello", into: sourceText, at: 0)
    }
    let sourceAwareness = YAwareness(document: sourceDoc)

    let remoteDoc = YDoc(clientID: 2)
    let remoteText = try remoteDoc.text(named: "body")
    let remoteAwareness = YAwareness(document: remoteDoc)
    let request = try YSyncMessage.syncStep1(remoteDoc.stateVector())

    let response = try YSyncProtocol.handle(request.payload, awareness: sourceAwareness)
    let responseMessages = try YSyncMessage.decodePayload(response)
    #expect(responseMessages.count == 1)
    if case .syncStep2 = responseMessages[0] {} else {
        Issue.record("Expected sync step 2 response")
    }

    let reply = try YSyncProtocol.handle(response, awareness: remoteAwareness)
    #expect(reply.isEmpty)
    try remoteDoc.read { transaction in
        try #expect(transaction.string(from: remoteText) == "hello")
    }
}

@Test
func syncProtocolStartReturnsStepOneAndAwarenessMessages() throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    try awareness.setLocalState(["name": "Ada"])

    let payload = try YSyncProtocol.start(awareness: awareness)
    let messages = try YSyncMessage.decodePayload(payload)

    #expect(messages.count == 2)
    if case .syncStep1 = messages[0] {} else {
        Issue.record("Expected sync step 1")
    }
    if case .awareness = messages[1] {} else {
        Issue.record("Expected awareness")
    }
}

@Test(arguments: ["start", "syncStep1", "syncStep2", "update"])
func syncProtocolDoesNotHoldAwarenessLockDuringDocumentAccess(operation: String) async throws {
    let source = YDoc(clientID: 1)
    let text = try source.text(named: "body")
    try source.write { try $0.insert("hello", into: text, at: 0) }
    let update = try source.encodeStateAsUpdateV1()
    let doc = YDoc(clientID: 2)
    let awareness = YAwareness(document: doc)
    let payload: Data
    switch operation {
    case "syncStep1": payload = try YSyncMessage.syncStep1(source.stateVector()).payload
    case "syncStep2": payload = try YSyncMessage.syncStep2(update).payload
    default: payload = try YSyncMessage.update(update).payload
    }
    let transactionHeld = AsyncStream.makeStream(of: Void.self)
    let setPresence = DispatchSemaphore(value: 0)
    defer { setPresence.signal() }
    let writerFinished = DispatchSemaphore(value: 0)
    let syncFinished = AsyncStream.makeStream(of: Void.self)
    let writerResult = SyncAttemptResult()
    let syncResult = SyncAttemptResult()

    Thread {
        defer { writerFinished.signal() }
        writerResult.record {
            try doc.write { _ in
                transactionHeld.continuation.yield(())
                setPresence.wait()
                try awareness.setLocalState(["cursor": 42])
            }
            return Data()
        }
    }.start()
    let acquired = await testCompletion(transactionHeld.stream)
    #expect(acquired, "Writer must acquire its transaction")
    guard acquired else {
        setPresence.signal()
        return
    }
    Thread {
        defer { syncFinished.continuation.yield(()) }
        syncResult.record {
            // The first real conflict proves sync reached the held document transaction.
            // Only one conflict is expected: release presence and await the writer here.
            let retry = YSyncProtocol.RetryPolicy(
                now: { .zero }, wait: { _ in },
                onConflict: { setPresence.signal(); writerFinished.wait() }
            )
            if operation == "start" { return try YSyncProtocol.start(awareness: awareness, retry: retry) }
            return try YSyncProtocol.handle(payload, awareness: awareness, retry: retry)
        }
    }.start()

    let completed = await testCompletion(syncFinished.stream)
    #expect(completed, "Sync and setting presence inside the writer transaction must complete without deadlock")
    guard completed else { return }
    #expect(syncResult.error() == nil)
    #expect(writerResult.error() == nil)
    #expect(try (awareness.localState() as? [String: Any])?["cursor"] as? Int == 42)

    if operation == "start" {
        #expect(try YSyncMessage.decodePayload(syncResult.data()).count == 2)
    } else {
        let responses = try YSyncMessage.decodePayload(syncResult.data())
        #expect(responses.count == (operation == "syncStep1" ? 1 : 0))
        if operation != "syncStep1" {
            let targetText = try doc.text(named: "body")
            try doc.read { try #expect($0.string(from: targetText) == "hello") }
        }
    }
}

@Test(arguments: [false, true], [false, true])
func syncProtocolSameThreadContentionThrowsAfterDeadline(starting: Bool, inObserver: Bool) async throws {
    let source = YDoc(clientID: 1)
    let text = try source.text(named: "body")
    try source.write { try $0.insert("hello", into: text, at: 0) }
    let payload = try YSyncMessage.update(source.encodeStateAsUpdateV1()).payload
    let doc = YDoc(clientID: 2)
    let awareness = YAwareness(document: doc)
    let result = SyncAttemptResult()
    let finished = AsyncStream.makeStream(of: Void.self)
    let clock = SyncRetryClock()
    Thread {
        defer { finished.continuation.yield(()) }
        let sync = {
            let retry = YSyncProtocol.RetryPolicy(now: { clock.now() }, wait: { clock.advance($0) })
            if starting { return try YSyncProtocol.start(awareness: awareness, retry: retry) }
            return try YSyncProtocol.handle(payload, awareness: awareness, retry: retry)
        }
        do {
            if inObserver {
                let observation = try doc.observeUpdates { _ in result.record(sync) }
                defer { observation.cancel() }
                let targetText = try doc.text(named: "body")
                try doc.write { try $0.insert("local", into: targetText, at: 0) }
            } else {
                try doc.write { _ in result.record(sync) }
            }
        } catch {
            result.record { throw error }
        }
    }.start()
    let completed = await testCompletion(finished.stream)
    #expect(completed, "Re-entrant sync must time out rather than deadlock")
    guard completed else { return }
    #expect(result.error() as? YError == .transactionConflict)
    #expect(clock.now() == .seconds(1))
}

@Test
func syncProtocolRejectsMalformedBatchBeforeApplyingEarlierMessages() throws {
    let source = YDoc(clientID: 1)
    let sourceText = try source.text(named: "body")
    try source.write { try $0.insert("hello", into: sourceText, at: 0) }
    let sourceAwareness = YAwareness(document: source)
    try sourceAwareness.setLocalState(["name": "peer"])
    let messages = [
        try YSyncMessage.update(source.encodeStateAsUpdateV1()),
        try YSyncMessage.awareness(sourceAwareness.encodeUpdate())
    ]
    let doc = YDoc(clientID: 2)
    let text = try doc.text(named: "body")
    let awareness = YAwareness(document: doc)
    let payload = YSyncMessage.joinedPayload(messages) + Data([0xff, 0xff])

    #expect(throws: YError.decodeFailure) {
        try YSyncProtocol.handle(payload, awareness: awareness)
    }
    try doc.read { try #expect($0.string(from: text).isEmpty) }
    #expect(try awareness.states().isEmpty)
}

@Test
func syncProtocolRoutesAwarenessAndQueriesWithOrigin() throws {
    let peer = YAwareness(document: YDoc(clientID: 1))
    try peer.setLocalState(["name": "peer"])
    let awareness = YAwareness(document: YDoc(clientID: 2))
    var changes: [YAwarenessChange] = []
    let observation = try awareness.observeUpdate { event in
        if case let .awarenessUpdate(change) = event { changes.append(change) }
    }
    defer { observation.cancel() }
    let messages = [try YSyncMessage.awareness(peer.encodeUpdate()), try .awarenessQuery()]

    let response = try YSyncProtocol.handle(
        YSyncMessage.joinedPayload(messages), awareness: awareness, origin: "custom-provider"
    )
    #expect(changes.count == 1)
    #expect(changes.first?.origin == "custom-provider")
    let replies = try YSyncMessage.decodePayload(response)
    #expect(replies.count == 1)
    if case let .awareness(update, _) = try #require(replies.first) {
        let receiver = YAwareness(document: YDoc(clientID: 3))
        try receiver.applyUpdate(update)
        #expect(try (receiver.state(for: 1) as? [String: Any])?["name"] as? String == "peer")
    } else {
        Issue.record("Expected awareness query response")
    }

    try peer.setLocalState(["name": "changed"])
    _ = try YSyncProtocol.handle(YSyncMessage.awareness(peer.encodeUpdate()).payload, awareness: awareness)
    #expect(changes.count == 2)
    #expect(changes.last?.origin == nil)
}

private final class SyncAttemptResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func record(_ operation: () throws -> Data) {
        let result = Result(catching: operation)
        lock.withLock { self.result = result }
    }

    func error() -> Error? {
        lock.withLock {
            if case let .failure(error) = result { return error }
            return nil
        }
    }

    func data() throws -> Data {
        try lock.withLock {
            guard let result else { throw YError.decodeFailure }
            return try result.get()
        }
    }
}

@Test
func syncDecodeRejectsMalformedPayloads() throws {
    #expect(throws: YError.decodeFailure) {
        try YSyncMessage.decodePayload(Data([0xff, 0xff]))
    }
}

@Test
func syncCanDecodeJavaScriptYjsFixture() throws {
    let fixture = try YjsSyncFixture.load("sync-messages")
    let decoded = try YSyncMessage.decodePayload(fixture.multiMessage)

    #expect(decoded.count == 4)
    if case .syncStep1 = decoded[0] {} else {
        Issue.record("Expected JS sync step 1")
    }
    if case let .update(update, _) = decoded[1] {
        let doc = YDoc(clientID: 22)
        let text = try doc.text(named: "body")
        try doc.write { transaction in
            try transaction.apply(update)
        }
        try doc.read { transaction in
            try #expect(transaction.string(from: text) == "from js")
        }
    } else {
        Issue.record("Expected JS update")
    }
    if case let .awareness(update, _) = decoded[2] {
        let awareness = YAwareness(document: YDoc(clientID: 22))
        try awareness.applyUpdate(update)
        let state = try #require(awareness.state(for: 21) as? [String: Any])
        #expect(state["name"] as? String == "sync-js")
    } else {
        Issue.record("Expected JS awareness")
    }
    if case .awarenessQuery = decoded[3] {} else {
        Issue.record("Expected JS awareness query")
    }
}

private final class SyncRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero
    func now() -> Duration { lock.withLock { time } }
    func advance(_ duration: Duration) { lock.withLock { time += duration } }
}

