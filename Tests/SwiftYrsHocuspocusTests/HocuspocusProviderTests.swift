import Foundation
import SwiftYrsTestSupport
import Testing
import SwiftYrs
@testable import SwiftYrsHocuspocus

@Suite(.serialized)
struct HocuspocusProviderTests {

@Test
func providersSharingAwarenessForwardInboundUpdatesWithoutEchoingToSource() async throws {
    let document = YDoc(clientID: 89)
    let awareness = YAwareness(document: document)
    let sourceSocket = FakeHocuspocusWebSocket()
    let otherSocket = FakeHocuspocusWebSocket()
    let sourceForwards = LockedCounter()
    let source = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        testHooks: .init(onAwarenessForwarded: { _ = sourceForwards.increment() }),
        webSocketFactory: { _ in sourceSocket }
    )
    let other = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        webSocketFactory: { _ in otherSocket }
    )
    try await source.connect()
    try await other.connect()
    for _ in 0..<2 {
        _ = try await sourceSocket.requireSentMessage()
        _ = try await otherSocket.requireSentMessage()
    }
    let remote = YAwareness(document: YDoc(clientID: 90))
    try remote.setLocalState(["name": "remote"])
    sourceSocket.receive(HocuspocusMessage.awareness(documentName: "room-1", try remote.encodeUpdate()).encoded())
    let message = try HocuspocusMessage.decode(
        try await otherSocket.requireSentMessage()
    )
    if case let .awareness(_, update) = message {
        let receiver = YAwareness(document: YDoc(clientID: 88))
        try receiver.applyUpdate(update)
        #expect(try (receiver.state(for: 90) as? [String: Any])?["name"] as? String == "remote")
    } else {
        Issue.record("Expected awareness forwarded by the other provider")
    }
    try await receiveLoopMarker(source, socket: sourceSocket)
    #expect(sourceForwards.value() == 0)
    #expect(sourceSocket.sentMessageCount() == 0)
    await source.disconnect()
    let removal = try HocuspocusMessage.decode(
        try await otherSocket.requireSentMessage()
    )
    #expect(removal == .awareness(
        documentName: "room-1", YAwarenessUpdate(Data([1, 90, 1, 4] + Array("null".utf8)))
    ))
    #expect(sourceSocket.sentMessageCount() == 0)
    await other.disconnect()
}

@Test
func providerBroadcastsRepeatedLocalNullButNotAbsentClientRemoval() async throws {
    let document = YDoc(clientID: 99)
    let awareness = YAwareness(document: document, timing: .init(checkInterval: .seconds(3600)))
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        webSocketFactory: { _ in socket }
    )
    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    for clock: UInt8 in 1...3 {
        if clock == 3 { try awareness.setLocalStateJSON(Data("null".utf8)) }
        else { awareness.clearLocalState() }
        let message = try HocuspocusMessage.decode(
            try await socket.requireSentMessage()
        )
        #expect(message == .awareness(
            documentName: "room-1", YAwarenessUpdate(Data([1, 99, clock, 4] + Array("null".utf8)))
        ))
    }
    awareness.removeStates(for: [99])
    try await receiveLoopMarker(provider, socket: socket)
    #expect(socket.sentMessageCount() == 0)
    await provider.disconnect()
}

@Test
func providerRenewsIdleAwarenessLocallyAfterDisconnect() async throws {
    let clock = ProviderAwarenessClock()
    let scheduler = AwarenessChecks()
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
        testHooks: .init(awarenessCheckWait: { await scheduler.wait() }, onAwarenessCheck: { scheduler.checked($0) }),
        webSocketFactory: { _ in socket }
    )
    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()

    try await scheduler.park()
    clock.set(.milliseconds(14_999))
    #expect(try await scheduler.tick())
    #expect(try awareness.encodeUpdate() == initial)
    #expect(socket.sentMessageCount() == 0)
    clock.set(.seconds(15))
    #expect(try await scheduler.tick())
    let message = try HocuspocusMessage.decode(
        try await socket.requireSentMessage()
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
    let disconnected = try awareness.encodeUpdate()
    clock.set(.seconds(60))
    #expect(try await scheduler.tick())
    #expect(try awareness.encodeUpdate() != disconnected)
    #expect(socket.sentMessageCount() == 0)
}

@Test
func providerExpiresSilentRemoteAwarenessWithTimeoutChange() async throws {
    let clock = ProviderAwarenessClock()
    let scheduler = AwarenessChecks()
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
        testHooks: .init(awarenessCheckWait: { await scheduler.wait() }, onAwarenessCheck: { scheduler.checked($0) }),
        webSocketFactory: { _ in socket }
    )
    let changes = try awareness.changeEvents()
    try await provider.connect()
    try await scheduler.park()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    let peer = YAwareness(document: YDoc(clientID: 94))
    try peer.setLocalState(["name": "silent"])
    socket.receive(HocuspocusMessage.awareness(documentName: "room-1", try peer.encodeUpdate()).encoded())
    if case let .awarenessChange(change) = try await nextTestEvent(changes) {
        #expect(change.added == [94])
    } else {
        Issue.record("Expected remote awareness arrival")
    }

    clock.set(.seconds(30))
    #expect(try await scheduler.tick())
    if case let .awarenessChange(change) = try await nextTestEvent(changes) {
        #expect(change.removed == [94])
        #expect(change.origin == YAwarenessChange.timeoutOrigin)
    } else {
        Issue.record("Expected timeout removal")
    }
    let message = try HocuspocusMessage.decode(
        try await socket.requireSentMessage()
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
    #expect(try await scheduler.tick())
}

@Test
func providerDoesNotRenewNullAwareness() async throws {
    let clock = ProviderAwarenessClock()
    let scheduler = AwarenessChecks()
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
        testHooks: .init(awarenessCheckWait: { await scheduler.wait() }, onAwarenessCheck: { scheduler.checked($0) }),
        webSocketFactory: { _ in socket }
    )
    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    clock.set(.seconds(60))
    #expect(try await scheduler.tick())
    #expect(socket.sentMessageCount() == 0)
    await provider.disconnect()
    #expect(try await scheduler.tick())
}

@Test
func providerRenewsAwarenessDuringUnexpectedDisconnectAndSendsCurrentClockOnReconnect() async throws {
    let clock = ProviderAwarenessClock()
    let scheduler = AwarenessChecks()
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
        maxRetries: 0,
        testHooks: .init(awarenessCheckWait: { await scheduler.wait() }, onAwarenessCheck: { scheduler.checked($0) }),
        webSocketFactory: { _ in factory.next() }
    )
    let statuses = provider.connectionStatus
    try await provider.connect()
    try await scheduler.park()
    _ = try await nextTestEvent(statuses)
    _ = try await nextTestEvent(statuses)
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    try await scheduler.park()
    socket.failReceive()
    #expect(try await nextTestEvent(statuses) == .disconnected)
    clock.set(.seconds(60))
    #expect(try await scheduler.tick())
    #expect(socket.sentMessageCount() == 0)
    #expect(try awareness.encodeUpdate() != initial)
    let disconnected = try awareness.encodeUpdate()

    try await provider.connect()
    _ = try await nextSocket.requireSentMessage()
    _ = try await nextSocket.requireSentMessage()
    let message = try HocuspocusMessage.decode(
        try await nextSocket.requireSentMessage()
    )
    if case let .awareness(_, update) = message {
        #expect(update == disconnected)
    } else {
        Issue.record("Expected current awareness on reconnect")
    }
    clock.set(.seconds(75))
    #expect(try await scheduler.tick())
    _ = try await nextSocket.requireSentMessage()
    await provider.disconnect()
    let stopped = try awareness.encodeUpdate()
    clock.set(.seconds(120))
    #expect(try await scheduler.tick())
    #expect(try awareness.encodeUpdate() != stopped)
    #expect(nextSocket.sentMessageCount() == 0)
}

@Test
func providerRenewsAwarenessBeforeFirstConnect() async throws {
    let clock = ProviderAwarenessClock()
    let checks = AwarenessChecks()
    let document = YDoc(clientID: 98)
    let awareness = YAwareness(
        document: document, timing: .init(checkInterval: .milliseconds(5)), now: { clock.now() }
    )
    try awareness.setLocalState(["name": "idle"])
    let initial = try awareness.encodeUpdate()
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        testHooks: .init(awarenessCheckWait: { await checks.wait() }, onAwarenessCheck: { checks.checked($0) }),
        webSocketFactory: { _ in socket }
    )
    clock.set(.seconds(15))
    try await checks.park()
    #expect(try await checks.tick())
    #expect(try awareness.encodeUpdate() != initial)
    #expect(socket.sentMessageCount() == 0)
    await provider.disconnect()
}

@Test
func providerAwarenessTimerDoesNotRetainDisconnectedProvider() async throws {
    let clock = ProviderAwarenessClock()
    let checks = AwarenessChecks()
    let document = YDoc(clientID: 100)
    let awareness = YAwareness(
        document: document, timing: .init(checkInterval: .milliseconds(5)), now: { clock.now() }
    )
    try awareness.setLocalState(["name": "idle"])
    let socket = FakeHocuspocusWebSocket()
    var provider: HocuspocusProvider? = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        testHooks: .init(awarenessCheckWait: { await checks.wait() }, onAwarenessCheck: { checks.checked($0) }),
        webSocketFactory: { _ in socket }
    )
    weak let weakProvider = provider
    try await provider?.connect()
    try await checks.park()
    let initial = try awareness.encodeUpdate()
    clock.set(.seconds(15))
    #expect(try await checks.tick())
    #expect(try awareness.encodeUpdate() != initial)
    await provider?.disconnect()
    provider = nil
    let released = try awareness.encodeUpdate()
    clock.set(.seconds(60))
    #expect(try await checks.tick() == false)
    #expect(weakProvider == nil)
    #expect(try awareness.encodeUpdate() == released)
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
    defer { heldWrite.stop() }
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: clientDocument,
        maxRetries: 1,
        initialDelay: .milliseconds(5),
        maxDelay: .milliseconds(5),
        testHooks: .init(onTransactionConflict: {
            do { try await heldWrite.release() } catch { Issue.record(error) }
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

    try await heldWrite.start()

    socket.receive(HocuspocusMessage.sync(
        documentName: "room-1",
        try YSyncMessage.syncStep2(update)
    ).encoded())
    _ = try await nextTestEvent(conflicts.stream)

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
    defer { heldWrite.stop() }
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: clientDocument,
        maxRetries: 1,
        initialDelay: .milliseconds(5),
        maxDelay: .milliseconds(5),
        testHooks: .init(onTransactionConflict: {
            do { try await heldWrite.release() } catch { Issue.record(error) }
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

    try await heldWrite.start()
    socket.receive(HocuspocusMessage.sync(
        documentName: "room-1",
        try YSyncMessage.syncStep1(serverDocument.stateVector())
    ).encoded())
    _ = try await nextTestEvent(conflicts.stream)

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
    #expect(try await nextTestEvent(provider.stateless) == "after-sync")
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
    defer { heldWrite.stop() }
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: clientDocument,
        maxRetries: 1,
        initialDelay: .milliseconds(5),
        maxDelay: .milliseconds(5),
        testHooks: .init(
            onTransactionConflict: {
                do { try await heldWrite.release() } catch { Issue.record(error) }
                conflicts.continuation.yield(())
            },
            onSyncMessageHandled: { index in
                if index == 0 {
                    do { try await heldWrite.start() } catch { Issue.record(error) }
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
    _ = try await nextTestEvent(conflicts.stream)

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
    #expect(try await nextTestEvent(provider.stateless) == "after-frame")
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
    defer { heldWrite.stop() }
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

    try await heldWrite.start()
    socket.receive(frame)
    var pauseIterator = pauseEntered.stream.makeAsyncIterator()
    _ = await pauseIterator.next()
    await provider.disconnect()
    #expect(await statusIterator.next() == .disconnected)
    try await heldWrite.release()
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
    defer { heldWrite.stop() }
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
                do { try await heldWrite.release() } catch { Issue.record(error) }
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

    try await heldWrite.start()
    firstSocket.receive(frame)
    for _ in 0..<8 {
        _ = try await nextTestEvent(conflicts.stream)
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
    let forwarded = LockedCounter()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: localDocument,
        testHooks: .init(onDocumentForwarded: { _ = forwarded.increment() }),
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

    try await receiveLoopMarker(provider, socket: socket)
    #expect(forwarded.value() == 1)
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
    let forwarded = LockedCounter()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: localDocument,
        testHooks: .init(onDocumentForwarded: { _ = forwarded.increment() }),
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
    try await receiveLoopMarker(provider, socket: socket)
    #expect(forwarded.value() == 0)
    #expect(socket.sentMessageCount() == 0)

    // A genuine local edit must still be propagated (the gate resets correctly).
    try localDocument.write { transaction in
        try transaction.insert("!", into: localText, at: 0)
    }
    let localFrame = try await socket.requireSentMessage()
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
    let localAwareness = YAwareness(document: localDocument, now: { .zero })
    try localAwareness.setLocalState(["name": "local"])
    let remoteAwareness = YAwareness(document: YDoc(clientID: 7))
    try remoteAwareness.setLocalState(["name": "remote"])
    let socket = FakeHocuspocusWebSocket()
    let forwarded = LockedCounter()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1",
        document: localDocument,
        awareness: localAwareness,
        testHooks: .init(onAwarenessForwarded: { _ = forwarded.increment() }),
        webSocketFactory: { _ in socket }
    )

    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()
    let initialAwarenessFrame = try await socket.requireSentMessage()
    #expect(try HocuspocusMessage.decode(initialAwarenessFrame) == .awareness(
        documentName: "room-1",
        try localAwareness.encodeUpdate(for: [localAwareness.clientID])
    ))

    socket.receive(HocuspocusMessage.awareness(documentName: "room-1", try remoteAwareness.encodeUpdate()).encoded())
    try await expectEventually {
        let state = try localAwareness.state(for: remoteAwareness.clientID) as? [String: Any]
        return state?["name"] as? String == "remote"
    }
    try await receiveLoopMarker(provider, socket: socket)
    #expect(forwarded.value() == 0)
    #expect(socket.sentMessageCount() == 0)

    try localAwareness.setLocalState(["name": "changed"])
    let changedFrame = try await socket.requireSentMessage()
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
    #expect(try localAwareness.encodeUpdate(for: [7]).data == Data([1, 7, 1, 4] + Array("null".utf8)))
    try remoteAwareness.setLocalState(["name": "returned"])
    try localAwareness.applyUpdate(remoteAwareness.encodeUpdate(for: [7]))
    #expect(try (localAwareness.state(for: 7) as? [String: Any])?["name"] as? String == "returned")
    #expect(socket.sentMessageCount() == 0)
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

    let response = try HocuspocusMessage.decode(try await socket.requireSentMessage())
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

@Test(arguments: [false, true])
func providerCloseRemovesRemoteAwarenessInOneEventWithoutBroadcast(unexpected: Bool) async throws {
    let document = YDoc(clientID: 1)
    let awareness = YAwareness(document: document)
    let peer = YAwareness(document: YDoc(clientID: 2))
    let other = YAwareness(document: YDoc(clientID: 3))
    try awareness.setLocalState(["name": "local"])
    try peer.setLocalState(["name": "peer"])
    try other.setLocalState(["name": "other"])
    try awareness.applyUpdate(peer.encodeUpdate())
    try awareness.applyUpdate(other.encodeUpdate())
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!, name: "room-1",
        document: document, awareness: awareness, maxRetries: 0,
        webSocketFactory: { _ in socket }
    )
    let statuses = provider.connectionStatus
    try await provider.connect()
    #expect(try await nextTestEvent(statuses) == .connecting)
    #expect(try await nextTestEvent(statuses) == .connected)
    for _ in 0..<3 { _ = try await socket.requireSentMessage() }
    var changes: [YAwarenessChange] = []
    var updates: [YAwarenessChange] = []
    let change = try awareness.observeChange {
        if case let .awarenessChange(event) = $0 { changes.append(event) }
    }
    let update = try awareness.observeUpdate {
        if case let .awarenessUpdate(event) = $0 { updates.append(event) }
    }
    defer { change.cancel(); update.cancel() }
    if unexpected { socket.failReceive() } else { await provider.disconnect() }
    #expect(try await nextTestEvent(statuses) == .disconnected)
    #expect(changes.count == 1)
    #expect(updates == changes)
    #expect(changes.first?.removed.sorted() == [2, 3])
    #expect(changes.first?.origin.flatMap(UUID.init(uuidString:)) != nil)
    #expect(try awareness.localState() != nil)
    #expect(try awareness.encodeUpdate(for: [2]).data == Data([1, 2, 1, 4] + Array("null".utf8)))
    #expect(try awareness.encodeUpdate(for: [3]).data == Data([1, 3, 1, 4] + Array("null".utf8)))
    #expect(socket.sentMessageCount() == 0)
    await provider.disconnect()
    #expect(updates.count == 1)
    try peer.setLocalState(["name": "returned"])
    try awareness.applyUpdate(peer.encodeUpdate())
    #expect(try (awareness.state(for: 2) as? [String: Any])?["name"] as? String == "returned")
}

@Test
func providerBroadcastsLocalRemovalAtIncrementedClock() async throws {
    let document = YDoc(clientID: 1)
    let awareness = YAwareness(document: document)
    try awareness.setLocalState(["name": "local"])
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!, name: "room-1",
        document: document, awareness: awareness, webSocketFactory: { _ in socket }
    )
    try await provider.connect()
    for _ in 0..<3 { _ = try await socket.requireSentMessage() }
    awareness.clearLocalState(origin: "page hide")
    let frame = try await socket.requireSentMessage()
    #expect(try HocuspocusMessage.decode(frame) == .awareness(
        documentName: "room-1", YAwarenessUpdate(Data([1, 1, 2, 4] + Array("null".utf8)))
    ))
    await provider.disconnect()
    #expect(socket.sentMessageCount() == 0)
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
        try HocuspocusMessage.decode(try await secondSocket.requireSentMessage()),
        try HocuspocusMessage.decode(try await secondSocket.requireSentMessage()),
        try HocuspocusMessage.decode(try await secondSocket.requireSentMessage()),
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

    try await provider.connect()
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    _ = try await firstSocket.requireSentMessage()
    _ = try await firstSocket.requireSentMessage()

    // A frame on the first socket proves the connection is healthy.
    firstSocket.receive(HocuspocusMessage.stateless(documentName: "room-1", payload: "ping-1").encoded())
    #expect(try await nextTestEvent(provider.stateless) == "ping-1")

    firstSocket.failReceive()
    #expect(await statusIterator.next() == .disconnected)
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    _ = try await secondSocket.requireSentMessage()
    _ = try await secondSocket.requireSentMessage()

    // A frame on the second socket again proves health, which must reset the
    // backoff counter so the next drop still reconnects despite maxRetries == 1.
    secondSocket.receive(HocuspocusMessage.stateless(documentName: "room-1", payload: "ping-2").encoded())
    #expect(try await nextTestEvent(provider.stateless) == "ping-2")

    secondSocket.failReceive()
    #expect(await statusIterator.next() == .disconnected)
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    _ = try await thirdSocket.requireSentMessage()

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

    try await provider.connect()
    _ = try await socket.requireSentMessage()
    _ = try await socket.requireSentMessage()

    await provider.sendStateless("client-ping")
    #expect(try HocuspocusMessage.decode(try await socket.requireSentMessage()) == .stateless(
        documentName: "room-1",
        payload: "client-ping"
    ))

    socket.receive(HocuspocusMessage.stateless(documentName: "room-1", payload: "server-pong").encoded())
    #expect(try await nextTestEvent(provider.stateless) == "server-pong")

    await provider.disconnect()
}


@Test(arguments: [false, true])
func destroyAwaitsFinalAwarenessWriteBeforeClosing(localStateIsNil: Bool) async throws {
    let document = YDoc(clientID: 120)
    let awareness = YAwareness(document: document, timing: .init(checkInterval: .seconds(3600)))
    if !localStateIsNil { try awareness.setLocalState(["name": "leaving"]) }
    let removal = HocuspocusMessage.awareness(
        documentName: "room-1",
        YAwarenessUpdate(Data([1, 120, localStateIsNil ? 1 : 2, 4] + Array("null".utf8)))
    ).encoded()
    let gate = AsyncSendGate()
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        testHooks: .init(onSocketSend: { frame in
            if frame == removal { await gate.suspend() }
        }),
        webSocketFactory: { _ in socket }
    )
    defer { gate.open() }
    try await provider.connect()
    for _ in 0..<(localStateIsNil ? 2 : 3) { _ = try await socket.requireSentMessage() }

    let destroyed = Task { await provider.destroy() }
    try await gate.waitForEntry()
    #expect(socket.closeCount() == 0)
    #expect(socket.sentMessageCount() == 0)
    gate.open()
    try await testTaskValue(destroyed)
    #expect(socket.closeCount() == 1)
    #expect(try await socket.requireSentMessage() == removal)
    #expect(socket.sentMessageCount() == 0)
    #expect(try awareness.localState() == nil)
}

@Test
func destroySendsQueuedDocumentUpdateBeforeFinalAwareness() async throws {
    let document = YDoc(clientID: 121)
    let text = try document.text(named: "body")
    let awareness = YAwareness(document: document, timing: .init(checkInterval: .seconds(3600)))
    try awareness.setLocalState(["name": "leaving"])
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        webSocketFactory: { _ in socket }
    )
    try await provider.connect()
    for _ in 0..<3 { _ = try await socket.requireSentMessage() }

    try document.write { transaction in try transaction.insert("bye", into: text, at: 0) }
    await provider.destroy()
    #expect(socket.closeCount() == 1)
    let update = try HocuspocusMessage.decode(try await socket.requireSentMessage())
    guard case let .sync(_, .update(payload, _)) = update else {
        Issue.record("Expected the document update before the awareness removal, got \(update)")
        return
    }
    let peer = YDoc(clientID: 122)
    let peerText = try peer.text(named: "body")
    try peer.write { transaction in try transaction.apply(payload) }
    #expect(try peer.read { transaction in try transaction.string(from: peerText) } == "bye")
    #expect(try HocuspocusMessage.decode(try await socket.requireSentMessage()) == .awareness(
        documentName: "room-1", YAwarenessUpdate(Data([1, 121, 2, 4] + Array("null".utf8)))
    ))
    #expect(socket.sentMessageCount() == 0)
}

@Test
func disconnectKeepsLocalPresenceForReconnect() async throws {
    let document = YDoc(clientID: 123)
    let awareness = YAwareness(document: document, timing: .init(checkInterval: .seconds(3600)))
    try awareness.setLocalState(["name": "away"])
    let before = try awareness.encodeUpdate(for: [123])
    let firstSocket = FakeHocuspocusWebSocket()
    let secondSocket = FakeHocuspocusWebSocket()
    let socketFactory = FakeSocketFactory([firstSocket, secondSocket])
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        webSocketFactory: { _ in socketFactory.next() }
    )
    try await provider.connect()
    for _ in 0..<3 { _ = try await firstSocket.requireSentMessage() }

    await provider.disconnect()
    #expect(firstSocket.closeCount() == 1)
    #expect(firstSocket.sentMessageCount() == 0)
    #expect(try awareness.encodeUpdate(for: [123]) == before)

    try await provider.connect()
    var messages: [HocuspocusMessage] = []
    for _ in 0..<3 { messages.append(try HocuspocusMessage.decode(try await secondSocket.requireSentMessage())) }
    #expect(messages.contains(.awareness(documentName: "room-1", before)))
    await provider.destroy()
}

@Test
func destroyIsIdempotentAndTerminalWithoutConnection() async throws {
    let document = YDoc(clientID: 124)
    let awareness = YAwareness(document: document, timing: .init(checkInterval: .seconds(3600)))
    try awareness.setLocalState(["name": "never connected"])
    let socketFactory = FakeSocketFactory([FakeHocuspocusWebSocket()])
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        webSocketFactory: { _ in socketFactory.next() }
    )
    await provider.destroy()
    let cleared = try awareness.encodeUpdate(for: [124])
    #expect(cleared.data == Data([1, 124, 2, 4] + Array("null".utf8)))
    await provider.destroy()
    #expect(try awareness.encodeUpdate(for: [124]) == cleared)
    try await provider.connect()
    #expect(socketFactory.createdCount() == 0)
    #expect(try await withTestTimeout { await finishedStatuses(provider) } == [.disconnected])
}

@Test
func destroyAfterSocketIsGoneAndRepeatedDestroyCloseOnce() async throws {
    let document = YDoc(clientID: 125)
    let awareness = YAwareness(document: document, timing: .init(checkInterval: .seconds(3600)))
    try awareness.setLocalState(["name": "dropped"])
    let droppedSocket = FakeHocuspocusWebSocket()
    let dropped = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness, maxRetries: 0,
        webSocketFactory: { _ in droppedSocket }
    )
    try await dropped.connect()
    #expect(try await nextTestEvent(dropped.connectionStatus) == .connecting)
    #expect(try await nextTestEvent(dropped.connectionStatus) == .connected)
    for _ in 0..<3 { _ = try await droppedSocket.requireSentMessage() }
    droppedSocket.failReceive()
    #expect(try await nextTestEvent(dropped.connectionStatus) == .disconnected)
    await dropped.destroy()
    await dropped.destroy()
    #expect(droppedSocket.closeCount() == 1)
    #expect(droppedSocket.sentMessageCount() == 0)
    #expect(try awareness.localState() == nil)

    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        webSocketFactory: { _ in socket }
    )
    try awareness.setLocalState(["name": "connected"])
    try await provider.connect()
    for _ in 0..<3 { _ = try await socket.requireSentMessage() }
    await provider.destroy()
    let removal = try await socket.requireSentMessage()
    await provider.destroy()
    #expect(try HocuspocusMessage.decode(removal) == .awareness(
        documentName: "room-1", try awareness.encodeUpdate(for: [125])
    ))
    #expect(try awareness.localState() == nil)
    #expect(socket.closeCount() == 1)
    #expect(socket.sentMessageCount() == 0)
}


@Test
func handshakeSuspendedInTokenRetrievalWritesNothingAfterDestroy() async throws {
    let tokenGate = AsyncSendGate()
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: YDoc(clientID: 140),
        token: { await tokenGate.suspend(); return "late" },
        webSocketFactory: { _ in socket }
    )
    defer { tokenGate.open() }
    let connecting = Task { () -> Bool in
        do { try await provider.connect(); return true } catch { return false }
    }
    try await tokenGate.waitForEntry()
    await provider.destroy()
    #expect(socket.closeCount() == 1)
    tokenGate.open()
    #expect(try await testTaskValue(connecting))
    #expect(socket.sentMessageCount() == 0)
}

@Test
func staleHandshakeContinuationDoesNotWriteToNewConnection() async throws {
    let tokenGate = AsyncSendGate()
    let tokenCalls = LockedCounter()
    let firstSocket = FakeHocuspocusWebSocket()
    let secondSocket = FakeHocuspocusWebSocket()
    let socketFactory = FakeSocketFactory([firstSocket, secondSocket])
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: YDoc(clientID: 141),
        token: {
            if tokenCalls.increment() == 1 { await tokenGate.suspend() }
            return "token"
        },
        webSocketFactory: { _ in socketFactory.next() }
    )
    defer { tokenGate.open() }
    let stale = Task { () -> Bool in
        do { try await provider.connect(); return true } catch { return false }
    }
    try await tokenGate.waitForEntry()
    await provider.disconnect()
    try await provider.connect()
    for _ in 0..<2 { _ = try await secondSocket.requireSentMessage() }

    tokenGate.open()
    #expect(try await testTaskValue(stale))
    await provider.sendStateless("marker")
    #expect(try HocuspocusMessage.decode(try await secondSocket.requireSentMessage()) == .stateless(
        documentName: "room-1", payload: "marker"
    ))
    #expect(firstSocket.sentMessageCount() == 0)
    #expect(secondSocket.sentMessageCount() == 0)
    await provider.destroy()
}

@Test
func inboundFrameReceivedDuringDestroyIsNotApplied() async throws {
    let document = YDoc(clientID: 70)
    let awareness = YAwareness(document: document, timing: .init(checkInterval: .seconds(3600)))
    try awareness.setLocalState(["name": "leaving"])
    let removal = HocuspocusMessage.awareness(
        documentName: "room-1", YAwarenessUpdate(Data([1, 70, 2, 4] + Array("null".utf8)))
    ).encoded()
    let gate = AsyncSendGate()
    let inbound = AsyncStream.makeStream(of: Bool.self)
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        testHooks: .init(
            onSocketSend: { frame in if frame == removal { await gate.suspend() } },
            onInboundFrame: { inbound.continuation.yield($0) }
        ),
        webSocketFactory: { _ in socket }
    )
    defer { gate.open() }
    try await provider.connect()
    for _ in 0..<3 { _ = try await socket.requireSentMessage() }

    let destroyed = Task { await provider.destroy() }
    try await gate.waitForEntry()
    let remote = YAwareness(document: YDoc(clientID: 71))
    try remote.setLocalState(["name": "late"])
    socket.receive(HocuspocusMessage.awareness(documentName: "room-1", try remote.encodeUpdate()).encoded())
    socket.receive(HocuspocusMessage.stateless(documentName: "room-1", payload: "late").encoded())
    #expect(try await nextTestEvent(inbound.stream) == false)
    #expect(try awareness.state(for: 71) == nil)
    gate.open()
    try await testTaskValue(destroyed)
    #expect(try await socket.requireSentMessage() == removal)
    #expect(try awareness.state(for: 71) == nil)
}

@Test
func destroyWaitsForObserverCallbackAlreadyRunning() async throws {
    let document = YDoc(clientID: 144)
    let text = try document.text(named: "body")
    let callbackGate = TestThreadGate()
    let armed = LockedCounter()
    let drainWait = AsyncStream.makeStream(of: Void.self)
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document,
        testHooks: .init(
            onDocumentForwarded: { if armed.value() > 0 { callbackGate.enterAndWait() } },
            onObserverDrainWait: { drainWait.continuation.yield(()) }
        ),
        webSocketFactory: { _ in socket }
    )
    defer { callbackGate.open() }
    try await provider.connect()
    for _ in 0..<2 { _ = try await socket.requireSentMessage() }

    _ = armed.increment()
    let written = AsyncStream.makeStream(of: Void.self)
    Thread {
        do {
            try document.write { transaction in try transaction.insert("late", into: text, at: 0) }
        } catch {
            Issue.record("Failed to write: \(error)")
        }
        written.continuation.yield(())
    }.start()
    try await callbackGate.waitForEntry()

    let destroyed = Task { await provider.destroy() }
    _ = try await nextTestEvent(drainWait.stream)
    #expect(socket.closeCount() == 0)
    callbackGate.open()
    try await testTaskValue(destroyed)
    _ = try await nextTestEvent(written.stream)
    #expect(socket.closeCount() == 1)
    let message = try HocuspocusMessage.decode(try await socket.requireSentMessage())
    guard case let .sync(_, .update(update, _)) = message else {
        Issue.record("Expected the observed update before close, got \(message)")
        return
    }
    let peer = YDoc(clientID: 145)
    let peerText = try peer.text(named: "body")
    try peer.write { transaction in try transaction.apply(update) }
    #expect(try peer.read { transaction in try transaction.string(from: peerText) } == "late")
    #expect(socket.sentMessageCount() == 0)
}

@Test(arguments: [false, true])
func droppingConnectionDiscardsQueuedAndHeldWrites(unexpected: Bool) async throws {
    let held = HocuspocusMessage.stateless(documentName: "room-1", payload: "held").encoded()
    let queued = HocuspocusMessage.stateless(documentName: "room-1", payload: "queued").encoded()
    let gate = AsyncSendGate()
    let discarded = AsyncStream.makeStream(of: Data.self)
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: YDoc(clientID: 146), maxRetries: 0,
        testHooks: .init(
            onSocketSend: { frame in if frame == held { await gate.suspend() } },
            onFrameDiscarded: { discarded.continuation.yield($0) }
        ),
        webSocketFactory: { _ in socket }
    )
    defer { gate.open() }
    try await provider.connect()
    #expect(try await nextTestEvent(provider.connectionStatus) == .connecting)
    #expect(try await nextTestEvent(provider.connectionStatus) == .connected)
    for _ in 0..<2 { _ = try await socket.requireSentMessage() }

    await provider.sendStateless("held")
    try await gate.waitForEntry()
    await provider.sendStateless("queued")
    if unexpected {
        socket.failReceive()
    } else {
        await provider.disconnect()
    }
    #expect(try await nextTestEvent(provider.connectionStatus) == .disconnected)
    #expect(try await nextTestEvent(discarded.stream) == queued)
    #expect(socket.closeCount() == 1)
    gate.open()
    #expect(try await nextTestEvent(discarded.stream) == held)
    #expect(socket.sentMessageCount() == 0)
    await provider.destroy()
}

@Test
func concurrentDestroyCallersWaitForTeardown() async throws {
    let document = YDoc(clientID: 72)
    let awareness = YAwareness(document: document, timing: .init(checkInterval: .seconds(3600)))
    try awareness.setLocalState(["name": "leaving"])
    let removal = HocuspocusMessage.awareness(
        documentName: "room-1", YAwarenessUpdate(Data([1, 72, 2, 4] + Array("null".utf8)))
    ).encoded()
    let gate = AsyncSendGate()
    let joined = AsyncStream.makeStream(of: Void.self)
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        testHooks: .init(
            onSocketSend: { frame in if frame == removal { await gate.suspend() } },
            onDestroyJoined: { joined.continuation.yield(()) }
        ),
        webSocketFactory: { _ in socket }
    )
    defer { gate.open() }
    try await provider.connect()
    for _ in 0..<3 { _ = try await socket.requireSentMessage() }

    let first = Task { await provider.destroy() }
    try await gate.waitForEntry()
    let second = Task { () -> Int in
        await provider.destroy()
        return socket.closeCount()
    }
    _ = try await nextTestEvent(joined.stream)
    #expect(socket.closeCount() == 0)
    gate.open()
    #expect(try await testTaskValue(second) == 1)
    try await testTaskValue(first)
    #expect(try await socket.requireSentMessage() == removal)
}

@Test
func slowSocketCoalescesQueuedAwarenessToLatestState() async throws {
    let document = YDoc(clientID: 148)
    let awareness = YAwareness(document: document, timing: .init(checkInterval: .seconds(3600)))
    let gate = AsyncSendGate()
    let armed = LockedCounter()
    let forwarded = AsyncStream.makeStream(of: Void.self)
    let socket = FakeHocuspocusWebSocket()
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, awareness: awareness,
        testHooks: .init(
            onAwarenessForwarded: { forwarded.continuation.yield(()) },
            onSocketSend: { _ in if armed.value() == 1, armed.increment() == 2 { await gate.suspend() } }
        ),
        webSocketFactory: { _ in socket }
    )
    defer { gate.open() }
    try await provider.connect()
    for _ in 0..<2 { _ = try await socket.requireSentMessage() }

    _ = armed.increment()
    try awareness.setLocalState(["n": 0])
    _ = try await nextTestEvent(forwarded.stream)
    try await gate.waitForEntry()
    for n in 1...50 {
        try awareness.setLocalState(["n": n])
        _ = try await nextTestEvent(forwarded.stream)
    }
    await provider.sendStateless("marker")
    gate.open()

    var states: [Int] = []
    for _ in 0..<2 {
        let message = try HocuspocusMessage.decode(try await socket.requireSentMessage())
        guard case let .awareness(_, update) = message else {
            Issue.record("Expected awareness, got \(message)")
            return
        }
        let peer = YAwareness(document: YDoc(clientID: 149))
        try peer.applyUpdate(update)
        states.append(try #require((peer.state(for: 148) as? [String: Any])?["n"] as? Int))
    }
    #expect(states == [0, 50])
    #expect(try HocuspocusMessage.decode(try await socket.requireSentMessage()) == .stateless(
        documentName: "room-1", payload: "marker"
    ))
    #expect(socket.sentMessageCount() == 0)
    await provider.destroy()
}

@Test
func slowSocketBacklogBeyondCapacityReconnectsAndResyncs() async throws {
    let document = YDoc(clientID: 150)
    let text = try document.text(named: "body")
    let held = HocuspocusMessage.stateless(documentName: "room-1", payload: "held").encoded()
    let gate = AsyncSendGate()
    let discarded = AsyncStream.makeStream(of: Data.self)
    let firstSocket = FakeHocuspocusWebSocket()
    let secondSocket = FakeHocuspocusWebSocket()
    let socketFactory = FakeSocketFactory([firstSocket, secondSocket])
    let provider = HocuspocusProvider(
        url: URL(string: "wss://example.com/collaboration")!,
        name: "room-1", document: document, maxRetries: 1, initialDelay: .zero,
        testHooks: .init(
            onSocketSend: { frame in if frame == held { await gate.suspend() } },
            onFrameDiscarded: { discarded.continuation.yield($0) }
        ),
        outboundCapacity: 4,
        webSocketFactory: { _ in socketFactory.next() }
    )
    defer { gate.open() }
    try await provider.connect()
    #expect(try await nextTestEvent(provider.connectionStatus) == .connecting)
    #expect(try await nextTestEvent(provider.connectionStatus) == .connected)
    for _ in 0..<2 { _ = try await firstSocket.requireSentMessage() }

    await provider.sendStateless("held")
    try await gate.waitForEntry()
    for index in 0..<5 {
        try document.write { transaction in try transaction.insert("\(index)", into: text, at: 0) }
    }
    await provider.sendStateless("trigger")
    #expect(try await nextTestEvent(provider.connectionStatus) == .disconnected)
    #expect(try await nextTestEvent(provider.connectionStatus) == .connecting)
    #expect(try await nextTestEvent(provider.connectionStatus) == .connected)
    var reconnect: [HocuspocusMessage] = []
    for _ in 0..<2 { reconnect.append(try HocuspocusMessage.decode(try await secondSocket.requireSentMessage())) }
    #expect(reconnect.contains { message in
        if case .sync(documentName: "room-1", .syncStep1) = message { return true }
        return false
    })
    #expect(firstSocket.closeCount() == 1)
    gate.open()
    var dropped: [Data] = []
    repeat { dropped.append(try await nextTestEvent(discarded.stream)) } while dropped.last != held
    // Five document updates and the trigger; the held write is discarded last.
    #expect(dropped.count == 7)
    #expect(firstSocket.sentMessageCount() == 0)
    await provider.destroy()
}

}

private final class FakeHocuspocusWebSocket: HocuspocusWebSocket, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeHocuspocusWebSocket")
    private var sentMessages: [Data] = []
    private var receiveMessages: [Data] = []
    private var sendContinuations: [(id: UUID, continuation: CheckedContinuation<Data, Error>)] = []
    private var receiveContinuations: [CheckedContinuation<Data, Error>] = []
    private var pendingError: Error?
    private var closes = 0

    func resume() {}

    func send(_ data: Data) {
        let continuation: CheckedContinuation<Data, Error>? = queue.sync {
            if !sendContinuations.isEmpty {
                return sendContinuations.removeFirst().continuation
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

    // Delivery is awaited directly; the shared watchdog bounds eventual completion.
    func requireSentMessage() async throws -> Data {
        try await withTestTimeout { try await self.waitForSentMessage() }
    }

    private func waitForSentMessage() async throws -> Data {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outcome: Result<Data, Error>? = queue.sync {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if !sentMessages.isEmpty { return .success(sentMessages.removeFirst()) }
                    sendContinuations.append((id, continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Data, Error>? = self.queue.sync {
                guard let index = self.sendContinuations.firstIndex(where: { $0.id == id }) else { return nil }
                return self.sendContinuations.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func sentMessageCount() -> Int {
        queue.sync {
            sentMessages.count
        }
    }
}

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
    private let started = AsyncStream.makeStream(of: Void.self)
    private let ended = AsyncStream.makeStream(of: Void.self)

    init(document: YDoc) {
        self.document = document
    }

    deinit {
        stop()
    }

    func start() async throws {
        guard begin() else { return }
        do {
            _ = try await nextTestEvent(started.stream)
        } catch {
            stop()
            throw error
        }
    }

    func release() async throws {
        guard markReleased() else { return }
        releaseSignal.signal()
        _ = try await nextTestEvent(ended.stream)
    }

    // Test defers must release the writer even if a watched event never arrives.
    func stop() {
        guard markReleased() else { return }
        releaseSignal.signal()
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
        Thread {
            do {
                try document.write { _ in
                    started.yield(())
                    releaseSignal.wait()
                }
            } catch {
                Issue.record("Failed to hold write transaction: \(error)")
                started.yield(())
            }
            ended.yield(())
        }.start()
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
    let deadline = ContinuousClock.now + .seconds(30)
    while true {
        if try predicate() {
            return
        }
        guard ContinuousClock.now < deadline else { break }
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


// A stateless marker is processed after preceding inbound frames on this actor.
private func receiveLoopMarker(_ provider: HocuspocusProvider, socket: FakeHocuspocusWebSocket) async throws {
    let marker = UUID().uuidString
    socket.receive(HocuspocusMessage.stateless(documentName: "room-1", payload: marker).encoded())
    #expect(try await nextTestEvent(provider.stateless) == marker)
}

// Suspends one socket write until the test driver opens it.
private final class AsyncSendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private let entered = AsyncStream.makeStream(of: Void.self)

    func suspend() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                guard !opened else { return true }
                self.continuation = continuation
                return false
            }
            entered.continuation.yield(())
            if resume { continuation.resume() }
        }
    }

    func waitForEntry() async throws { _ = try await nextTestEvent(entered.stream) }

    func open() {
        let continuation = lock.withLock {
            opened = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private func finishedStatuses(_ provider: HocuspocusProvider) async -> [ConnectionStatus] {
    var statuses: [ConnectionStatus] = []
    for await status in provider.connectionStatus { statuses.append(status) }
    return statuses
}
