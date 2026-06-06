import Foundation
import Testing
import SwiftYrs
@testable import SwiftYrsHocuspocus

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

private final class FakeHocuspocusWebSocket: HocuspocusWebSocket, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeHocuspocusWebSocket")
    private var sentMessages: [Data] = []
    private var receiveMessages: [Data] = []
    private var sendContinuations: [CheckedContinuation<Data, Never>] = []
    private var receiveContinuations: [CheckedContinuation<Data, Error>] = []

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
        if let data = queue.sync(execute: { receiveMessages.isEmpty ? nil : receiveMessages.removeFirst() }) {
            return data
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.sync {
                receiveContinuations.append(continuation)
            }
        }
    }

    func close() {
        let continuations = queue.sync {
            let continuations = receiveContinuations
            receiveContinuations.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
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

    func requireSentMessage() async throws -> Data {
        if let data = queue.sync(execute: { sentMessages.isEmpty ? nil : sentMessages.removeFirst() }) {
            return data
        }
        return await withCheckedContinuation { continuation in
            queue.sync {
                sendContinuations.append(continuation)
            }
        }
    }

    func sentMessageCount() -> Int {
        queue.sync {
            sentMessages.count
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
