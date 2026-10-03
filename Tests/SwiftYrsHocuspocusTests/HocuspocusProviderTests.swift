import Foundation
import Testing
import SwiftYrs
@testable import SwiftYrsHocuspocus

@Suite(.serialized)
struct HocuspocusProviderTests {

@Test
func providerRenewsIdleAwarenessAndStopsAfterDisconnectAndDestroy() async throws {
    let clock = ProviderAwarenessClock()
    let document = YDoc(clientID: 91)
    let awareness = YAwareness(
        document: document,
        timing: .init(checkInterval: .milliseconds(5)),
        now: { clock.now() }
    )
    try awareness.setLocalState(["name": "idle"])
    let initial = try awareness.encodeUpdate()
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        webSocketFactory: { _ in socket }
    )
    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()

    clock.set(.milliseconds(14_999))
    try await socket.expectNoSentMessage(for: .milliseconds(30))
    clock.set(.seconds(15))
    let message = try HocuspocusMessage.decode(
        try await socket.requireSentMessage(timeout: .milliseconds(500))
    )
    if case let .awareness(name, update) = message {
        #expect(name == "room-1")
        #expect(update != initial)
        let peer = YAwareness(document: YDoc(clientID: 92))
        try peer.applyUpdate(update)
        #expect(try (peer.state(for: 91) as? [String: Any])?["name"] as? String == "idle")
    } else {
        Issue.record("Expected idle awareness renewal")
    }
    await provider.disconnect()
    clock.set(.seconds(60))
    try await socket.expectNoSentMessage(for: .milliseconds(30))
    await provider.destroy()
    clock.set(.seconds(120))
    try await provider.connect()
    try await socket.expectNoSentMessage(for: .milliseconds(30))
}

@Test
func providerExpiresSilentRemoteAwarenessWithTimeoutChange() async throws {
    let clock = ProviderAwarenessClock()
    let document = YDoc(clientID: 93)
    let awareness = YAwareness(
        document: document,
        timing: .init(checkInterval: .milliseconds(5)),
        now: { clock.now() }
    )
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        webSocketFactory: { _ in socket }
    )
    var changes = try awareness.changeEvents().makeAsyncIterator()
    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    let peer = YAwareness(document: YDoc(clientID: 94))
    try peer.setLocalState(["name": "silent"])
    socket.receive(HocuspocusMessage.awareness(documentName: "room-1", try peer.encodeUpdate()).encoded())
    if case let .awarenessChange(change) = await changes.next() {
        #expect(change.added == [94])
    } else {
        Issue.record("Expected remote awareness arrival")
    }

    clock.set(.seconds(30))
    if case let .awarenessChange(change) = await changes.next() {
        #expect(change.removed == [94])
        #expect(change.origin == "timeout")
    } else {
        Issue.record("Expected timeout removal")
    }
    let message = try HocuspocusMessage.decode(
        try await socket.requireSentMessage(timeout: .milliseconds(500))
    )
    if case let .awareness(_, update) = message {
        let receiver = YAwareness(document: YDoc(clientID: 95))
        try receiver.applyUpdate(peer.encodeUpdate())
        try receiver.applyUpdate(update)
        #expect(try receiver.state(for: 94) == nil)
    } else {
        Issue.record("Expected timeout awareness update")
    }
    await provider.disconnect()
}

@Test
func providerDoesNotRenewNullAwareness() async throws {
    let clock = ProviderAwarenessClock()
    let document = YDoc(clientID: 96)
    let awareness = YAwareness(
        document: document,
        timing: .init(checkInterval: .milliseconds(5)),
        now: { clock.now() }
    )
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        webSocketFactory: { _ in socket }
    )
    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    clock.set(.seconds(60))
    try await socket.expectNoSentMessage(for: .milliseconds(30))
    await provider.destroy()
}

@Test
func providerStopsAwarenessDuringUnexpectedDisconnectAndResumesOnReconnect() async throws {
    let clock = ProviderAwarenessClock()
    let document = YDoc(clientID: 97)
    let awareness = YAwareness(
        document: document,
        timing: .init(checkInterval: .milliseconds(5)),
        now: { clock.now() }
    )
    try awareness.setLocalState(["name": "idle"])
    let initial = try awareness.encodeUpdate()
    let socket = FakeHocuspocusWebSocket()
    let nextSocket = FakeHocuspocusWebSocket()
    let factory = FakeSocketFactory([socket, nextSocket])
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        maxRetries: 0, webSocketFactory: { _ in factory.next() }
    )
    var statuses = provider.connectionStatus.makeAsyncIterator()
    try await provider.connect()
    _ = await statuses.next()
    _ = await statuses.next()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    socket.failReceive()
    #expect(await statuses.next() == .disconnected)
    clock.set(.seconds(60))
    try await socket.expectNoSentMessage(for: .milliseconds(30))
    #expect(try awareness.encodeUpdate() == initial)

    try await provider.connect()
    _ = try await nextSocket.requireSentMessage()
    _ = try await nextSocket.requireSentMessage()
    _ = try await nextSocket.requireSentMessage()
    let message = try HocuspocusMessage.decode(
        try await nextSocket.requireSentMessage(timeout: .milliseconds(500))
    )
    if case let .awareness(_, update) = message {
        #expect(update != initial)
    } else {
        Issue.record("Expected awareness renewal after reconnect")
    }
    await provider.destroy()
    clock.set(.seconds(120))
    try await nextSocket.expectNoSentMessage(for: .milliseconds(30))
}

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
func providerRetriesIncomingSyncAfterTransactionConflictWithoutReconnecting() async throws {
    let serverDocument = YDoc(clientID: 21)
    let serverText = try serverDocument.text(named: "body")
    try serverDocument.write { transaction in
        try transaction.insert("remote", into: serverText, at: 0)
    }

    let clientDocument = YDoc(clientID: 22)
    let clientText = try clientDocument.text(named: "body")
    let update = try serverDocument.encodeStateAsUpdateV1(from: clientDocument.stateVector())
    let socket = FakeHocuspocusWebSocket()
    let replacementSocket = FakeHocuspocusWebSocket()
    let socketFactory = FakeSocketFactory([socket, replacementSocket])
    let conflicts = AsyncStream.makeStream(of: Void.self)
    let statuses = ConnectionStatusRecorder()
    let heldWrite = HeldWriteTransaction(document: clientDocument)
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: clientDocument,
        maxRetries: 1,
        initialDelay: .milliseconds(5),
        maxDelay: .milliseconds(5),
        testHooks: .init(onTransactionConflict: {
            heldWrite.releaseAndWait()
            conflicts.continuation.yield(())
        }),
        webSocketFactory: { _ in socketFactory.next() }
    )
    let statusTask = Task {
        for await status in provider.connectionStatus {
            statuses.append(status)
        }
    }
    defer { statusTask.cancel() }

    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    await statuses.waitForCount(2)
    #expect(statuses.values() == [.connecting, .connected])

    await heldWrite.start()

    socket.receive(HocuspocusMessage.sync(
        documentName: "room-1",
        try YSyncMessage.syncStep2(update)
    ).encoded())
    var conflictIterator = conflicts.stream.makeAsyncIterator()
    _ = await conflictIterator.next()

    var syncIterator = provider.isSynced.makeAsyncIterator()
    #expect(await syncIterator.next() == true)
    try clientDocument.read { transaction in
        try #expect(transaction.string(from: clientText) == "remote")
    }
    #expect(!statuses.values().contains(.disconnected))
    #expect(socket.closeCount() == 0)
    #expect(socketFactory.createdCount() == 1)

    await provider.disconnect()
}

@Test
func providerRetriesSyncStepOneReplyWithoutDuplicatingIt() async throws {
    let clientDocument = YDoc(clientID: 23)
    let clientText = try clientDocument.text(named: "body")
    try clientDocument.write { transaction in
        try transaction.insert("local", into: clientText, at: 0)
    }
    let serverDocument = YDoc(clientID: 24)
    let serverText = try serverDocument.text(named: "body")
    let socket = FakeHocuspocusWebSocket()
    let socketFactory = FakeSocketFactory([socket, FakeHocuspocusWebSocket()])
    let conflicts = AsyncStream.makeStream(of: Void.self)
    let statuses = ConnectionStatusRecorder()
    let heldWrite = HeldWriteTransaction(document: clientDocument)
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: clientDocument,
        maxRetries: 1,
        initialDelay: .milliseconds(5),
        maxDelay: .milliseconds(5),
        testHooks: .init(onTransactionConflict: {
            heldWrite.releaseAndWait()
            conflicts.continuation.yield(())
        }),
        webSocketFactory: { _ in socketFactory.next() }
    )
    let statusTask = Task {
        for await status in provider.connectionStatus {
            statuses.append(status)
        }
    }
    defer { statusTask.cancel() }
    var statelessIterator = provider.stateless.makeAsyncIterator()

    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    await statuses.waitForCount(2)
    #expect(statuses.values() == [.connecting, .connected])

    await heldWrite.start()
    socket.receive(HocuspocusMessage.sync(
        documentName: "room-1",
        try YSyncMessage.syncStep1(serverDocument.stateVector())
    ).encoded())
    var conflictIterator = conflicts.stream.makeAsyncIterator()
    _ = await conflictIterator.next()

    let reply = try HocuspocusMessage.decode(try await socket.requireSentMessage())
    if case let .sync(documentName, .syncStep2(update, _)) = reply {
        #expect(documentName == "room-1")
        try serverDocument.apply(update)
    } else {
        Issue.record("Expected one SyncStep2 reply")
    }
    try serverDocument.read { transaction in
        try #expect(transaction.string(from: serverText) == "local")
    }

    socket.receive(HocuspocusMessage.stateless(documentName: "room-1", payload: "after-sync").encoded())
    #expect(await statelessIterator.next() == "after-sync")
    #expect(socket.sentMessageCount() == 0)
    #expect(!statuses.values().contains(.disconnected))
    #expect(socket.closeCount() == 0)
    #expect(socketFactory.createdCount() == 1)

    await provider.disconnect()
}

@Test
func providerRetriesWholeSyncFrameWithoutDuplicatingReplies() async throws {
    let sourceDocument = YDoc(clientID: 28)
    let sourceText = try sourceDocument.text(named: "body")
    try sourceDocument.write { transaction in
        try transaction.insert("A", into: sourceText, at: 0)
    }
    let clientDocument = YDoc(clientID: 29)
    let clientText = try clientDocument.text(named: "body")
    let serverDocument = YDoc(clientID: 30)
    let serverText = try serverDocument.text(named: "body")
    let socket = FakeHocuspocusWebSocket()
    let socketFactory = FakeSocketFactory([socket, FakeHocuspocusWebSocket()])
    let conflicts = AsyncStream.makeStream(of: Void.self)
    let statuses = ConnectionStatusRecorder()
    let syncEvents = LockedCounter()
    let heldWrite = HeldWriteTransaction(document: clientDocument)
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: clientDocument,
        maxRetries: 1,
        initialDelay: .milliseconds(5),
        maxDelay: .milliseconds(5),
        testHooks: .init(
            onTransactionConflict: {
                heldWrite.releaseAndWait()
                conflicts.continuation.yield(())
            },
            onSyncMessageHandled: { index in
                if index == 0 {
                    heldWrite.startAndWait()
                }
            },
            onSyncStatusEmitted: { _ = syncEvents.increment() }
        ),
        webSocketFactory: { _ in socketFactory.next() }
    )
    let statusTask = Task {
        for await status in provider.connectionStatus {
            statuses.append(status)
        }
    }
    defer { statusTask.cancel() }
    var statelessIterator = provider.stateless.makeAsyncIterator()

    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    await statuses.waitForCount(2)
    #expect(statuses.values() == [.connecting, .connected])
    let frame = HocuspocusMessage.syncMessages(documentName: "room-1", [
        try YSyncMessage.syncStep2(sourceDocument.encodeStateAsUpdateV1()),
        try YSyncMessage.syncStep1(serverDocument.stateVector()),
    ]).encoded()
    socket.receive(frame)
    var conflictIterator = conflicts.stream.makeAsyncIterator()
    _ = await conflictIterator.next()

    let reply = try HocuspocusMessage.decode(try await socket.requireSentMessage())
    if case let .sync(documentName, .syncStep2(update, _)) = reply {
        #expect(documentName == "room-1")
        try serverDocument.apply(update)
    } else {
        Issue.record("Expected one SyncStep2 reply")
    }
    try clientDocument.read { transaction in
        try #expect(transaction.string(from: clientText) == "A")
    }
    try serverDocument.read { transaction in
        try #expect(transaction.string(from: serverText) == "A")
    }

    socket.receive(HocuspocusMessage.stateless(documentName: "room-1", payload: "after-frame").encoded())
    #expect(await statelessIterator.next() == "after-frame")
    #expect(socket.sentMessageCount() == 0)
    #expect(syncEvents.value() == 1)
    #expect(!statuses.values().contains(.disconnected))
    #expect(socket.closeCount() == 0)
    #expect(socketFactory.createdCount() == 1)

    await provider.disconnect()
}

@Test
func providerStopsTransactionRetryWhenDisconnected() async throws {
    let serverDocument = YDoc(clientID: 31)
    let serverText = try serverDocument.text(named: "body")
    try serverDocument.write { transaction in
        try transaction.insert("remote", into: serverText, at: 0)
    }
    let clientDocument = YDoc(clientID: 32)
    let clientText = try clientDocument.text(named: "body")
    let frame = HocuspocusMessage.sync(
        documentName: "room-1",
        try YSyncMessage.syncStep2(serverDocument.encodeStateAsUpdateV1())
    ).encoded()
    let socket = FakeHocuspocusWebSocket()
    let replacementSocket = FakeHocuspocusWebSocket()
    let socketFactory = FakeSocketFactory([socket, replacementSocket])
    let pauseEntered = AsyncStream.makeStream(of: Void.self)
    let pauseGate = AsyncStream.makeStream(of: Void.self)
    let pauseExited = AsyncStream.makeStream(of: Void.self)
    let heldWrite = HeldWriteTransaction(document: clientDocument)
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: clientDocument,
        maxRetries: 1,
        testHooks: .init(transactionRetryWait: {
            pauseEntered.continuation.yield(())
            defer { pauseExited.continuation.yield(()) }
            var iterator = pauseGate.stream.makeAsyncIterator()
            _ = await iterator.next()
            try Task.checkCancellation()
        }),
        webSocketFactory: { _ in socketFactory.next() }
    )
    var statusIterator = provider.connectionStatus.makeAsyncIterator()

    try await provider.connect()
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()

    await heldWrite.start()
    socket.receive(frame)
    var pauseIterator = pauseEntered.stream.makeAsyncIterator()
    _ = await pauseIterator.next()
    await provider.disconnect()
    #expect(await statusIterator.next() == .disconnected)
    await heldWrite.release()
    pauseGate.continuation.finish()
    var exitedIterator = pauseExited.stream.makeAsyncIterator()
    _ = await exitedIterator.next()

    #expect(socketFactory.createdCount() == 1)
    #expect(socket.sentMessageCount() == 0)
    #expect(replacementSocket.sentMessageCount() == 0)
    try clientDocument.read { transaction in
        try #expect(transaction.string(from: clientText) == "")
    }
}

@Test
func providerReconnectsAfterIncomingTransactionRetriesAreExhausted() async throws {
    let serverDocument = YDoc(clientID: 25)
    let serverText = try serverDocument.text(named: "body")
    try serverDocument.write { transaction in
        try transaction.insert("resynced", into: serverText, at: 0)
    }
    let clientDocument = YDoc(clientID: 26)
    let clientText = try clientDocument.text(named: "body")
    let update = try serverDocument.encodeStateAsUpdateV1(from: clientDocument.stateVector())
    let frame = HocuspocusMessage.sync(documentName: "room-1", try YSyncMessage.syncStep2(update)).encoded()
    let firstSocket = FakeHocuspocusWebSocket()
    let secondSocket = FakeHocuspocusWebSocket()
    let socketFactory = FakeSocketFactory([firstSocket, secondSocket])
    let conflicts = AsyncStream.makeStream(of: Void.self)
    let statuses = ConnectionStatusRecorder()
    let heldWrite = HeldWriteTransaction(document: clientDocument)
    let conflictCount = LockedCounter()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: clientDocument,
        maxRetries: 1,
        initialDelay: .milliseconds(5),
        maxDelay: .milliseconds(5),
        testHooks: .init(onTransactionConflict: {
            if conflictCount.increment() == 8 {
                heldWrite.releaseAndWait()
            }
            conflicts.continuation.yield(())
        }),
        webSocketFactory: { _ in socketFactory.next() }
    )
    let statusTask = Task {
        for await status in provider.connectionStatus {
            statuses.append(status)
        }
    }
    defer { statusTask.cancel() }
    var syncIterator = provider.isSynced.makeAsyncIterator()

    try await provider.connect()
    _ = try await firstSocket.requireSentMessage()
    _ = try await firstSocket.requireSentMessage()
    await statuses.waitForCount(2)
    #expect(statuses.values() == [.connecting, .connected])

    await heldWrite.start()
    firstSocket.receive(frame)
    var conflictIterator = conflicts.stream.makeAsyncIterator()
    for _ in 0..<8 {
        _ = await conflictIterator.next()
    }

    _ = try await secondSocket.requireSentMessage()
    let handshake = try HocuspocusMessage.decode(try await secondSocket.requireSentMessage())
    if case .sync(documentName: "room-1", .syncStep1) = handshake {} else {
        Issue.record("Expected a fresh SyncStep1 after retry exhaustion")
    }
    await statuses.waitForCount(5)
    #expect(statuses.values() == [.connecting, .connected, .disconnected, .connecting, .connected])
    #expect(firstSocket.closeCount() == 1)
    #expect(socketFactory.createdCount() == 2)
    try clientDocument.read { transaction in
        try #expect(transaction.string(from: clientText) == "")
    }

    secondSocket.receive(frame)
    #expect(await syncIterator.next() == true)
    try clientDocument.read { transaction in
        try #expect(transaction.string(from: clientText) == "resynced")
    }

    await provider.disconnect()
}

@Test
func providerStillReconnectsAfterNonConflictHandlingError() async throws {
    let firstSocket = FakeHocuspocusWebSocket()
    let secondSocket = FakeHocuspocusWebSocket()
    let socketFactory = FakeSocketFactory([firstSocket, secondSocket])
    let tokens = FailingOnceToken()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: YDoc(clientID: 27),
        token: { try await tokens.next() },
        maxRetries: 1,
        initialDelay: .milliseconds(5),
        maxDelay: .milliseconds(5),
        webSocketFactory: { _ in socketFactory.next() }
    )
    var statusIterator = provider.connectionStatus.makeAsyncIterator()

    try await provider.connect()
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    _ = try await firstSocket.requireSentMessage()
    _ = try await firstSocket.requireSentMessage()

    firstSocket.receive(HocuspocusMessage.auth(
        documentName: "room-1",
        .token("refresh", version: "server")
    ).encoded())

    #expect(await statusIterator.next() == .disconnected)
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    #expect(try HocuspocusMessage.decode(try await secondSocket.requireSentMessage()) == .auth(
        documentName: "room-1",
        .token("token-3", version: HocuspocusProvider.productName)
    ))
    #expect(firstSocket.closeCount() == 1)
    #expect(socketFactory.createdCount() == 2)

    await provider.disconnect()
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
func providerDoesNotEchoRemoteUpdatesButStillSendsLocalEdits() async throws {
    let localDocument = YDoc(clientID: 14)
    let localText = try localDocument.text(named: "body")
    let remoteDocument = YDoc(clientID: 15)
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

    // Apply several remote updates; none of them must be echoed back, regardless
    // of how yrs re-encodes the observed update bytes.
    var expected = ""
    for fragment in ["one", "two", "three"] {
        let base = try remoteDocument.read { try $0.length(of: remoteText) }
        try remoteDocument.write { transaction in
            try transaction.insert(fragment, into: remoteText, at: base)
        }
        expected += fragment
        let remoteUpdate = try remoteDocument.encodeStateAsUpdateV1(from: localDocument.stateVector())
        socket.receive(try HocuspocusMessage.sync(documentName: "room-1", YSyncMessage.update(remoteUpdate)).encoded())
        let snapshot = expected
        try await expectEventually {
            try localDocument.read { transaction in
                try transaction.string(from: localText) == snapshot
            }
        }
    }
    try await socket.expectNoSentMessage(for: .milliseconds(20))

    // A genuine local edit must still be propagated (the gate resets correctly).
    try localDocument.write { transaction in
        try transaction.insert("!", into: localText, at: 0)
    }
    let localFrame = try await socket.requireSentMessage(timeout: .milliseconds(100))
    if case .sync(documentName: "room-1", .update) = try HocuspocusMessage.decode(localFrame) {} else {
        Issue.record("Expected local edit to be sent as a Sync update")
    }

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
    private var closes = 0

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
        queue.sync { closes += 1 }
        failAllReceives(with: CancellationError())
    }

    func closeCount() -> Int {
        queue.sync { closes }
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
private struct TestTokenError: Error {}

private final class ProviderAwarenessClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero

    func now() -> Duration { lock.withLock { time } }
    func set(_ time: Duration) { lock.withLock { self.time = time } }
}

private final class HeldWriteTransaction: @unchecked Sendable {
    private let document: YDoc
    private let lock = NSLock()
    private var startedWork = false
    private var released = false
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let startedSignal = DispatchSemaphore(value: 0)
    private let endedSignal = DispatchSemaphore(value: 0)
    private let started = AsyncStream.makeStream(of: Void.self)
    private let ended = AsyncStream.makeStream(of: Void.self)

    init(document: YDoc) {
        self.document = document
    }

    deinit {
        releaseSignal.signal()
    }

    func start() async {
        begin()
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func startAndWait() {
        if begin() {
            startedSignal.wait()
        }
    }

    func releaseAndWait() {
        guard markReleased() else { return }
        releaseSignal.signal()
        endedSignal.wait()
    }

    func release() async {
        guard markReleased() else { return }
        releaseSignal.signal()
        var iterator = ended.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    @discardableResult
    private func begin() -> Bool {
        let shouldStart = lock.withLock {
            guard !startedWork else { return false }
            startedWork = true
            return true
        }
        guard shouldStart else { return false }

        let document = self.document
        let started = self.started.continuation
        let ended = self.ended.continuation
        let releaseSignal = self.releaseSignal
        let startedSignal = self.startedSignal
        let endedSignal = self.endedSignal
        DispatchQueue.global().async {
            do {
                try document.write { _ in
                    started.yield(())
                    startedSignal.signal()
                    releaseSignal.wait()
                }
            } catch {
                Issue.record("Failed to hold write transaction: \(error)")
                started.yield(())
                startedSignal.signal()
            }
            ended.yield(())
            endedSignal.signal()
        }
        return true
    }

    private func markReleased() -> Bool {
        lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    func value() -> Int {
        lock.withLock { count }
    }
}

private final class ConnectionStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [ConnectionStatus] = []
    private let signal = AsyncStream.makeStream(of: Void.self)

    func append(_ status: ConnectionStatus) {
        lock.withLock { statuses.append(status) }
        signal.continuation.yield(())
    }

    func values() -> [ConnectionStatus] {
        lock.withLock { statuses }
    }

    func waitForCount(_ count: Int) async {
        var iterator = signal.stream.makeAsyncIterator()
        while values().count < count {
            _ = await iterator.next()
        }
    }
}

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

private actor FailingOnceToken {
    private var calls = 0

    func next() throws -> String {
        calls += 1
        if calls == 2 {
            throw TestTokenError()
        }
        return "token-\(calls)"
    }
}
