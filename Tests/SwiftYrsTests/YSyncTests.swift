import Foundation
import Testing
import SwiftYrs

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
func syncProtocolDoesNotHoldAwarenessLockDuringDocumentAccess(operation: String) throws {
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
    let transactionHeld = DispatchSemaphore(value: 0)
    let setPresence = DispatchSemaphore(value: 0)
    let writerFinished = DispatchSemaphore(value: 0)
    let syncFinished = DispatchSemaphore(value: 0)
    let writerResult = SyncAttemptResult()
    let syncResult = SyncAttemptResult()

    DispatchQueue.global().async {
        defer { writerFinished.signal() }
        writerResult.record {
            try doc.write { _ in
                transactionHeld.signal()
                guard setPresence.wait(timeout: .now() + 5) == .success else {
                    throw YError.transactionConflict
                }
                try awareness.setLocalState(["cursor": 42])
            }
            return Data()
        }
    }
    guard transactionHeld.wait(timeout: .now() + 5) == .success else {
        setPresence.signal()
        Issue.record("Writer did not acquire its transaction")
        return
    }
    DispatchQueue.global().async {
        defer { syncFinished.signal() }
        syncResult.record {
            if operation == "start" { return try YSyncProtocol.start(awareness: awareness) }
            return try YSyncProtocol.handle(payload, awareness: awareness)
        }
    }

    let completedSync = syncFinished.wait(timeout: .now() + 1) == .success
    setPresence.signal()
    let completedWriter = writerFinished.wait(timeout: .now() + 2) == .success
    #expect(completedSync, "Sync must report contention without blocking")
    #expect(completedWriter, "Setting presence inside a document transaction must not deadlock")
    guard completedSync && completedWriter else { return }
    #expect(syncResult.error() as? YError == .transactionConflict)
    #expect(writerResult.error() == nil)
    #expect(try (awareness.localState() as? [String: Any])?["cursor"] as? Int == 42)

    if operation == "start" {
        #expect(try YSyncMessage.decodePayload(YSyncProtocol.start(awareness: awareness)).count == 2)
    } else {
        _ = try YSyncProtocol.handle(payload, awareness: awareness)
        if operation != "syncStep1" {
            let targetText = try doc.text(named: "body")
            try doc.read { try #expect($0.string(from: targetText) == "hello") }
        }
    }
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
