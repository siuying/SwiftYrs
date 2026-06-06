import Foundation
import Testing
import SwiftYrs
@testable import SwiftYrsHocuspocus

@Suite(.serialized)
struct HocuspocusProviderTests {

@Test
func providerConnectsSendsSyncStepOneAndAppliesSyncStepTwo() async throws {
    let serverDocument = YDoc(clientID: 1)
    let serverText = try serverDocument.text(named: "body")
    try serverDocument.write { transaction in
        try transaction.insert("hello", into: serverText, at: 0)
    }

    let clientDocument = YDoc(clientID: 2)
    let clientText = try clientDocument.text(named: "body")
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: clientDocument,
        webSocketFactory: { _ in socket }
    )

    var statusIterator = provider.connectionStatus.makeAsyncIterator()
    var syncIterator = provider.isSynced.makeAsyncIterator()

    try await provider.connect()

    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)

    #expect(try HocuspocusMessage.decode(try await socket.requireSentMessage()) == .auth(
        documentName: "room-1",
        .token("", version: HocuspocusProvider.productName)
    ))
    let sentMessage = try await socket.requireSentMessage()
    let decodedSentMessage = try HocuspocusMessage.decode(sentMessage)
    if case .sync(documentName: "room-1", .syncStep1) = decodedSentMessage {} else {
        Issue.record("Expected initial SyncStep1")
    }

    let syncStep2 = try YSyncMessage.syncStep2(serverDocument.encodeStateAsUpdateV1(from: clientDocument.stateVector()))
    socket.receive(HocuspocusMessage.sync(documentName: "room-1", syncStep2).encoded())

    #expect(await syncIterator.next() == true)
    try clientDocument.read { transaction in
        try #expect(transaction.string(from: clientText) == "hello")
    }

    await provider.disconnect()
    #expect(await statusIterator.next() == .disconnected)
}

@Test
func providerPropagatesLocalAndRemoteUpdatesWithoutEcho() async throws {
    let localDocument = YDoc(clientID: 3)
    let localText = try localDocument.text(named: "body")
    let remoteDocument = YDoc(clientID: 4)
    let remoteText = try remoteDocument.text(named: "body")
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: localDocument,
        webSocketFactory: { _ in socket }
    )

    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()

    try localDocument.write { transaction in
        try transaction.insert("local", into: localText, at: 0)
    }

    let localUpdateFrame = try await socket.requireSentMessage()
    if case let .sync(documentName: "room-1", .update(update, _)) = try HocuspocusMessage.decode(localUpdateFrame) {
        try remoteDocument.apply(update)
    } else {
        Issue.record("Expected local write to be sent as a Sync update")
    }

    try remoteDocument.write { transaction in
        try transaction.insert(" remote", into: remoteText, at: 5)
    }
    let remoteUpdate = try remoteDocument.encodeStateAsUpdateV1(from: localDocument.stateVector())
    let remoteUpdateFrame = try HocuspocusMessage.sync(
        documentName: "room-1",
        YSyncMessage.update(remoteUpdate)
    ).encoded()
    socket.receive(remoteUpdateFrame)

    try await expectEventually {
        try localDocument.read { transaction in
            try transaction.string(from: localText) == "local remote"
        }
    }

    try await Task.sleep(for: .milliseconds(20))
    #expect(socket.sentMessageCount() == 0)

    await provider.disconnect()
}

@Test
func providerSendsFreshAuthTokenAndEmitsAuthStatuses() async throws {
    let socket = FakeHocuspocusWebSocket()
    let tokenCounter = TokenCounter()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: YDoc(clientID: 5),
        token: {
            await tokenCounter.next()
        },
        webSocketFactory: { _ in socket }
    )
    var authIterator = provider.authStatus.makeAsyncIterator()

    try await provider.connect()

    let authFrame = try await socket.requireSentMessage()
    #expect(try HocuspocusMessage.decode(authFrame) == .auth(
        documentName: "room-1",
        .token("token-1", version: HocuspocusProvider.productName)
    ))
    _ = try await socket.requireSentMessage()

    socket.receive(HocuspocusMessage.auth(documentName: "room-1", .authenticated(scope: "read-write")).encoded())
    #expect(await authIterator.next() == .authenticated(scope: "read-write"))

    socket.receive(HocuspocusMessage.auth(documentName: "room-1", .permissionDenied(reason: "expired")).encoded())
    #expect(await authIterator.next() == .denied(reason: "expired"))

    await provider.disconnect()
    try await provider.connect()

    let secondAuthFrame = try await socket.requireSentMessage()
    #expect(try HocuspocusMessage.decode(secondAuthFrame) == .auth(
        documentName: "room-1",
        .token("token-2", version: HocuspocusProvider.productName)
    ))

    await provider.disconnect()
}

@Test
func providerSynchronizesAwarenessAndClearsRemoteStatesOnDisconnect() async throws {
    let localDocument = YDoc(clientID: 6)
    let localAwareness = YAwareness(document: localDocument)
    try localAwareness.setLocalState(["name": "local"])
    let remoteAwareness = YAwareness(document: YDoc(clientID: 7))
    try remoteAwareness.setLocalState(["name": "remote"])
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: localDocument,
        awareness: localAwareness,
        webSocketFactory: { _ in socket }
    )

    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    let initialAwarenessFrame = try await socket.requireSentMessage(timeout: .milliseconds(100))
    #expect(try HocuspocusMessage.decode(initialAwarenessFrame) == .awareness(
        documentName: "room-1",
        try localAwareness.encodeUpdate(for: [localAwareness.clientID])
    ))

    socket.receive(HocuspocusMessage.awareness(documentName: "room-1", try remoteAwareness.encodeUpdate()).encoded())
    try await expectEventually {
        let state = try localAwareness.state(for: remoteAwareness.clientID) as? [String: Any]
        return state?["name"] as? String == "remote"
    }
    try await socket.expectNoSentMessage(for: .milliseconds(20))

    try localAwareness.setLocalState(["name": "changed"])
    let changedFrame = try await socket.requireSentMessage(timeout: .milliseconds(100))
    if case let .awareness(documentName: "room-1", update) = try HocuspocusMessage.decode(changedFrame) {
        try remoteAwareness.applyUpdate(update)
    } else {
        Issue.record("Expected local awareness update")
    }
    let remoteLocalState = try #require(remoteAwareness.state(for: localAwareness.clientID) as? [String: Any])
    #expect(remoteLocalState["name"] as? String == "changed")

    await provider.disconnect()
    #expect(try localAwareness.state(for: remoteAwareness.clientID) == nil)
    #expect(try localAwareness.localState() != nil)
}

@Test
func providerAnswersAwarenessQueriesWithKnownStates() async throws {
    let document = YDoc(clientID: 11)
    let awareness = YAwareness(document: document)
    try awareness.setLocalState(["name": "swift"])
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: document,
        awareness: awareness,
        webSocketFactory: { _ in socket }
    )

    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()

    socket.receive(HocuspocusMessage.queryAwareness(documentName: "room-1").encoded())

    let response = try HocuspocusMessage.decode(try await socket.requireSentMessage(timeout: .milliseconds(100)))
    if case let .awareness(documentName: "room-1", update) = response {
        let remoteAwareness = YAwareness(document: YDoc(clientID: 12))
        try remoteAwareness.applyUpdate(update)
        let state = try #require(remoteAwareness.state(for: awareness.clientID) as? [String: Any])
        #expect(state["name"] as? String == "swift")
    } else {
        Issue.record("Expected awareness response")
    }

    await provider.disconnect()
}

@Test
func providerReconnectsAfterUnexpectedCloseAndResendsHandshake() async throws {
    let document = YDoc(clientID: 8)
    let awareness = YAwareness(document: document)
    try awareness.setLocalState(["name": "reconnect"])
    let firstSocket = FakeHocuspocusWebSocket()
    let secondSocket = FakeHocuspocusWebSocket()
    let socketFactory = FakeSocketFactory([firstSocket, secondSocket])
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: document,
        awareness: awareness,
        maxRetries: 1,
        initialDelay: .milliseconds(5),
        maxDelay: .milliseconds(20),
        webSocketFactory: { _ in socketFactory.next() }
    )
    var statusIterator = provider.connectionStatus.makeAsyncIterator()

    try await provider.connect()
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    _ = try await firstSocket.requireSentMessage()
    _ = try await firstSocket.requireSentMessage()
    _ = try await firstSocket.requireSentMessage()

    firstSocket.failReceive()

    #expect(await statusIterator.next() == .disconnected)
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    let reconnectMessages = [
        try HocuspocusMessage.decode(try await secondSocket.requireSentMessage(timeout: .milliseconds(100))),
        try HocuspocusMessage.decode(try await secondSocket.requireSentMessage(timeout: .milliseconds(100))),
        try HocuspocusMessage.decode(try await secondSocket.requireSentMessage(timeout: .milliseconds(100))),
    ]
    #expect(reconnectMessages.contains { message in
        if case .auth(documentName: "room-1", .token("", version: HocuspocusProvider.productName)) = message {
            return true
        }
        return false
    })
    #expect(reconnectMessages.contains { message in
        if case .sync(documentName: "room-1", .syncStep1) = message {
            return true
        }
        return false
    })
    #expect(reconnectMessages.contains { message in
        if case .awareness(documentName: "room-1", _) = message {
            return true
        }
        return false
    })

    await provider.disconnect()
}

@Test
func providerResetsBackoffAfterHealthyReconnect() async throws {
    let firstSocket = FakeHocuspocusWebSocket()
    let secondSocket = FakeHocuspocusWebSocket()
    let thirdSocket = FakeHocuspocusWebSocket()
    let socketFactory = FakeSocketFactory([firstSocket, secondSocket, thirdSocket])
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: YDoc(clientID: 13),
        maxRetries: 1,
        initialDelay: .milliseconds(5),
        maxDelay: .milliseconds(20),
        webSocketFactory: { _ in socketFactory.next() }
    )
    var statusIterator = provider.connectionStatus.makeAsyncIterator()
    var statelessIterator = provider.stateless.makeAsyncIterator()

    try await provider.connect()
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    _ = try await firstSocket.requireSentMessage()
    _ = try await firstSocket.requireSentMessage()

    // A frame on the first socket proves the connection is healthy.
    firstSocket.receive(HocuspocusMessage.stateless(documentName: "room-1", payload: "ping-1").encoded())
    #expect(await statelessIterator.next() == "ping-1")

    firstSocket.failReceive()
    #expect(await statusIterator.next() == .disconnected)
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    _ = try await secondSocket.requireSentMessage()
    _ = try await secondSocket.requireSentMessage()

    // A frame on the second socket again proves health, which must reset the
    // backoff counter so the next drop still reconnects despite maxRetries == 1.
    secondSocket.receive(HocuspocusMessage.stateless(documentName: "room-1", payload: "ping-2").encoded())
    #expect(await statelessIterator.next() == "ping-2")

    secondSocket.failReceive()
    #expect(await statusIterator.next() == .disconnected)
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    _ = try await thirdSocket.requireSentMessage(timeout: .milliseconds(100))

    await provider.disconnect()
}

@Test
func providerBackoffDelayIsExponentialAndCapped() {
    #expect(HocuspocusProvider.reconnectDelay(
        attempt: 0,
        initialDelay: .milliseconds(10),
        maxDelay: .milliseconds(100)
    ) == .milliseconds(10))
    #expect(HocuspocusProvider.reconnectDelay(
        attempt: 3,
        initialDelay: .milliseconds(10),
        maxDelay: .milliseconds(100)
    ) == .milliseconds(80))
    #expect(HocuspocusProvider.reconnectDelay(
        attempt: 6,
        initialDelay: .milliseconds(10),
        maxDelay: .milliseconds(100)
    ) == .milliseconds(100))
}

@Test
func providerSendsAndReceivesStatelessMessages() async throws {
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: YDoc(clientID: 10),
        webSocketFactory: { _ in socket }
    )
    var statelessIterator = provider.stateless.makeAsyncIterator()

    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()

    await provider.sendStateless("client-ping")
    #expect(try HocuspocusMessage.decode(try await socket.requireSentMessage()) == .stateless(
        documentName: "room-1",
        payload: "client-ping"
    ))

    socket.receive(HocuspocusMessage.stateless(documentName: "room-1", payload: "server-pong").encoded())
    #expect(await statelessIterator.next() == "server-pong")

    await provider.disconnect()
}

}

private final class FakeHocuspocusWebSocket: HocuspocusWebSocket, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeHocuspocusWebSocket")
    private var sentMessages: [Data] = []
    private var receiveMessages: [Data] = []
    private var sendContinuations: [CheckedContinuation<Data, Never>] = []
    private var receiveContinuations: [CheckedContinuation<Data, Error>] = []
    private var pendingError: Error?

    func resume() {}

    func send(_ data: Data) {
        let continuation: CheckedContinuation<Data, Never>? = queue.sync {
            if !sendContinuations.isEmpty {
                return sendContinuations.removeFirst()
            }
            sentMessages.append(data)
            return nil
        }
        continuation?.resume(returning: data)
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let outcome: Result<Data, Error>? = queue.sync {
                if !receiveMessages.isEmpty {
                    return .success(receiveMessages.removeFirst())
                }
                if let pendingError {
                    return .failure(pendingError)
                }
                receiveContinuations.append(continuation)
                return nil
            }
            if let outcome {
                continuation.resume(with: outcome)
            }
        }
    }

    func close() {
        failAllReceives(with: CancellationError())
    }

    func failReceive() {
        failAllReceives(with: TestWebSocketError())
    }

    private func failAllReceives(with error: Error) {
        let continuations: [CheckedContinuation<Data, Error>] = queue.sync {
            // Remember the failure so a receive() that hasn't parked yet still observes it,
            // instead of dropping the signal and hanging forever.
            if pendingError == nil {
                pendingError = error
            }
            let continuations = receiveContinuations
            receiveContinuations.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    func receive(_ data: Data) {
        let continuation: CheckedContinuation<Data, Error>? = queue.sync {
            if !receiveContinuations.isEmpty {
                return receiveContinuations.removeFirst()
            }
            receiveMessages.append(data)
            return nil
        }
        continuation?.resume(returning: data)
    }

    func requireSentMessage(timeout: Duration = .seconds(1)) async throws -> Data {
        if timeout == .seconds(1) {
            return await requireSentMessage()
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let data = dequeueSentMessage() {
                return data
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TimeoutError()
    }

    func expectNoSentMessage(for duration: Duration) async throws {
        do {
            _ = try await requireSentMessage(timeout: duration)
            Issue.record("Expected no sent message")
        } catch is TimeoutError {
        }
    }

    private func requireSentMessage() async -> Data {
        await withCheckedContinuation { continuation in
            let buffered: Data? = queue.sync {
                if !sentMessages.isEmpty {
                    return sentMessages.removeFirst()
                }
                sendContinuations.append(continuation)
                return nil
            }
            if let buffered {
                continuation.resume(returning: buffered)
            }
        }
    }

    private func dequeueSentMessage() -> Data? {
        queue.sync {
            sentMessages.isEmpty ? nil : sentMessages.removeFirst()
        }
    }

    func sentMessageCount() -> Int {
        queue.sync {
            sentMessages.count
        }
    }
}

private struct TimeoutError: Error {}
private struct TestWebSocketError: Error {}

private final class FakeSocketFactory: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeSocketFactory")
    private var sockets: [FakeHocuspocusWebSocket]
    private var created = 0

    init(_ sockets: [FakeHocuspocusWebSocket]) {
        self.sockets = sockets
    }

    func next() -> FakeHocuspocusWebSocket {
        queue.sync {
            created += 1
            return sockets.removeFirst()
        }
    }

    func createdCount() -> Int {
        queue.sync {
            created
        }
    }
}

private func expectEventually(_ predicate: @escaping () throws -> Bool) async throws {
    for _ in 0..<50 {
        if try predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try predicate())
}

private actor TokenCounter {
    private var value = 0

    func next() -> String {
        value += 1
        return "token-\(value)"
    }
}
