import Foundation
import SwiftYrsTestSupport
import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

@Test
func webRTCAwarenessRenewsExpiresThroughDisconnectAndStopsAtDestroy() async throws {
    let clock = WebRTCAwarenessClock()
    let scheduler = AwarenessChecks()
    let document = YDoc(clientID: 301)
    let awareness = YAwareness(
        document: document,
        timing: .init(checkInterval: .milliseconds(5)),
        now: { clock.now() }
    )
    try awareness.setLocalState(["name": "local"])
    let remote = YAwareness(document: YDoc(clientID: 302))
    try remote.setLocalState(["name": "remote"])
    try awareness.applyUpdate(remote.encodeUpdate())
    let provider = WebRTCProvider(
        "awareness-lifetime", doc: document, signaling: [],
        options: .init(awareness: awareness, iceServers: []),
        testHooks: .init(awarenessCheckWait: { await scheduler.wait() }, onAwarenessCheck: { scheduler.checked($0) })
    )
    let updates = try awareness.updateEvents()
    let changes = try awareness.changeEvents()
    let received = WebRTCAwarenessUpdates()
    let observation = try awareness.observeUpdate { _ in received.increment() }
    defer { observation.cancel() }
    try await provider.connect()
    clock.set(.seconds(15))
    #expect(try await scheduler.tick())
    if case let .awarenessUpdate(change) = try await nextTestEvent(updates) {
        #expect(change.updated == [301])
    } else {
        Issue.record("Expected WebRTC awareness renewal")
    }

    clock.set(.seconds(30))
    #expect(try await scheduler.tick())
    if case let .awarenessChange(change) = try await nextTestEvent(changes) {
        #expect(change.removed == [302])
        #expect(change.origin == YAwarenessChange.timeoutOrigin)
    } else {
        Issue.record("Expected WebRTC awareness expiry")
    }
    await provider.disconnect()
    try awareness.setLocalState(["name": "disconnected"])
    try remote.setLocalState(["name": "returned"])
    try awareness.applyUpdate(remote.encodeUpdate())
    let disconnected = try awareness.encodeUpdate(for: [301])
    clock.set(.seconds(60))
    #expect(try await scheduler.tick())
    #expect(try awareness.state(for: 302) == nil)
    #expect(try awareness.encodeUpdate(for: [301]) != disconnected)
    await provider.destroy()
    try awareness.setLocalState(["name": "after destroy"])
    try remote.setLocalState(["name": "after destroy"])
    try awareness.applyUpdate(remote.encodeUpdate())
    let destroyed = received.count()
    clock.set(.seconds(120))
    #expect(try await scheduler.tick() == false)
    #expect(received.count() == destroyed)
}

@Test(arguments: [false, true])
func webRTCAwarenessExpiresBeforeConnectAndDestroyStopsDisconnectedTimer(connectFirst: Bool) async throws {
    let clock = WebRTCAwarenessClock()
    let document = YDoc(clientID: 305)
    let awareness = YAwareness(
        document: document, timing: .init(checkInterval: .milliseconds(5)), now: { clock.now() }
    )
    try awareness.setLocalState(["name": "local"])
    let remote = YAwareness(document: YDoc(clientID: 306))
    try remote.setLocalState(["name": "remote"])
    try awareness.applyUpdate(remote.encodeUpdate())
    let provider = WebRTCProvider(
        "disconnected-awareness", doc: document, signaling: [],
        options: .init(awareness: awareness, iceServers: [])
    )
    if connectFirst {
        try await provider.connect()
        await provider.disconnect()
    }
    let removals = WebRTCAwarenessRemovals()
    let observation = try awareness.observeUpdate { event in
        if case let .awarenessUpdate(change) = event { removals.append(change) }
    }
    defer { observation.cancel() }
    clock.set(.seconds(30))
    try await e2eEventually("remote awareness expires while disconnected", timeout: .seconds(1)) {
        removals.values.contains(YAwarenessChange(
            added: [], updated: [], removed: [306], origin: YAwarenessChange.timeoutOrigin
        ))
    }
    #expect(try awareness.encodeUpdate(for: [306]).data == Data([1, 0xb2, 2, 1, 4] + Array("null".utf8)))
    if !connectFirst {
        #expect(removals.values.contains { $0.updated == [305] })
    }
    await provider.destroy()
    try awareness.setLocalState(["name": "after destroy"])
    try remote.setLocalState(["name": "after destroy"])
    try awareness.applyUpdate(remote.encodeUpdate())
    let destroyed = try [305, 306].map { try awareness.encodeUpdate(for: [$0]) }
    clock.set(.seconds(60))
    try await Task.sleep(for: .milliseconds(30))
    #expect(try [305, 306].map { try awareness.encodeUpdate(for: [$0]) } == destroyed)
    try await provider.connect()
    #expect(await provider.connected == false)
}

extension RealNetworkE2E {
    @Suite(.serialized)
    struct WebRTCAwarenessLifetimeTests {
        @Test
        func idleAwarenessRenewalReachesSwiftPeerOverDataChannel() async throws {
            try await withE2EProcesses { processes in
                let server = try processes.node(script: "webrtc-signaling-server.ts")
                let ready = try await server.waitForLine("signaling server ready") { $0["type"] as? String == "ready" }
                let port = try #require(ready["port"] as? Int)
                let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
                let clock = WebRTCAwarenessClock()
                let checks = AwarenessChecks()
                let document = YDoc(clientID: 303)
                let awareness = YAwareness(
                    document: document, timing: .init(checkInterval: .milliseconds(5)), now: { clock.now() }
                )
                try awareness.setLocalState(["name": "idle"])
                let provider = WebRTCProvider(
                    "awareness-renewal", doc: document, signaling: [url], options: .init(awareness: awareness, iceServers: []),
                    testHooks: .init(awarenessCheckWait: { await checks.wait() }, onAwarenessCheck: { checks.checked($0) })
                )
                let peerDocument = YDoc(clientID: 304)
                let peerAwareness = YAwareness(document: peerDocument)
                let peer = WebRTCProvider(
                    "awareness-renewal", doc: peerDocument, signaling: [url], options: .init(awareness: peerAwareness, iceServers: [])
                )
                let arrivals = AsyncStream.makeStream(of: Void.self)
                let arrivalObservation = try peerAwareness.observeUpdate { event in
                    if case let .awarenessUpdate(change) = event, change.changed.contains(303) {
                        arrivals.continuation.yield(())
                    }
                }
                defer { arrivalObservation.cancel() }
                try await withE2ETeardown([provider, peer]) {
                    try await provider.connect()
                    try await checks.park()
                    try await peer.connect()
                    #expect(await testCompletion(arrivals.stream), "Initial awareness reaches Swift peer")
                    #expect(try (peerAwareness.state(for: 303) as? [String: Any])?["name"] as? String == "idle")
                    let received = WebRTCAwarenessUpdates()
                    let renewals = AsyncStream.makeStream(of: Void.self)
                    let observation = try peerAwareness.observeUpdate { event in
                        if case let .awarenessUpdate(change) = event, change.updated.contains(303) {
                            received.increment()
                            renewals.continuation.yield(())
                        }
                    }
                    defer { observation.cancel() }
                    clock.set(.seconds(15))
                    #expect(try await checks.tick())
                    #expect(await testCompletion(renewals.stream), "Idle awareness renewal reaches Swift peer")
                    #expect(received.count() > 0)
                }
                #expect(try await checks.tick() == false)
            }
        }
    }
}

private final class WebRTCAwarenessUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    func count() -> Int { lock.withLock { value } }
}

private final class WebRTCAwarenessClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero

    func now() -> Duration { lock.withLock { time } }
    func set(_ time: Duration) { lock.withLock { self.time = time } }
}

@Test
func webRTCPeerCloseRetainsAwarenessUntilTimeoutAndAcceptsNextClock() async throws {
    let clock = WebRTCAwarenessClock()
    let document = YDoc(clientID: 1)
    let awareness = YAwareness(
        document: document, timing: .init(checkInterval: .seconds(3600)), now: { clock.now() }
    )
    let remote = YAwareness(document: YDoc(clientID: 2))
    try remote.setLocalState(["name": "remote"])
    let provider = WebRTCProvider(
        "peer-close-awareness", doc: document, signaling: [],
        options: .init(awareness: awareness, iceServers: [])
    )
    try await provider.connect()
    let peers = provider.peers
    await provider.handleSignal(from: "remote", token: 1, signal: .offer(sdp: "v=0"))
    #expect(try await nextTestEvent(peers)?.added == ["remote"])
    let connection = try #require(await provider.peerConnection(for: "remote"))
    let received = try #require(connection.onData)
    let closed = try #require(connection.onClosed)
    let updates = try awareness.updateEvents()
    received(try YSyncMessage.awareness(remote.encodeUpdate()).payload)
    if case let .awarenessUpdate(change) = try await nextTestEvent(updates) {
        #expect(change.added == [2])
        #expect(change.origin == "SwiftYrsWebRTC")
    } else {
        Issue.record("Expected remote awareness")
    }
    #expect(await provider.peerCount == 1)
    let beforeClose = try awareness.encodeUpdate(for: [2])
    let removals = WebRTCAwarenessRemovals()
    let observation = try awareness.observeUpdate { event in
        if case let .awarenessUpdate(change) = event, !change.removed.isEmpty { removals.append(change) }
    }
    defer { observation.cancel() }
    closed()
    #expect(try await nextTestEvent(peers)?.removed == ["remote"])
    #expect(await provider.peerCount == 0)
    #expect(try awareness.encodeUpdate(for: [2]) == beforeClose)
    #expect(removals.values.isEmpty)

    clock.set(.milliseconds(29_999))
    try awareness.checkTimeouts()
    #expect(try awareness.state(for: 2) != nil)
    clock.set(.seconds(30))
    try awareness.checkTimeouts()
    #expect(try awareness.state(for: 2) == nil)
    #expect(removals.values == [YAwarenessChange(added: [], updated: [], removed: [2], origin: YAwarenessChange.timeoutOrigin)])
    #expect(try awareness.encodeUpdate(for: [2]).data == Data([1, 2, 1, 4] + Array("null".utf8)))
    try remote.setLocalState(["name": "returned"])
    try awareness.applyUpdate(remote.encodeUpdate())
    #expect(try (awareness.state(for: 2) as? [String: Any])?["name"] as? String == "returned")
    await provider.destroy()
}

@Test(arguments: [false, true])
func webRTCStopsRemoveOnlyLocalAwarenessWithDisconnectOrigin(destroy: Bool) async throws {
    let document = YDoc(clientID: 1)
    let awareness = YAwareness(document: document, timing: .init(checkInterval: .seconds(3600)))
    let remote = YAwareness(document: YDoc(clientID: 2))
    try awareness.setLocalState(["name": "local"])
    try remote.setLocalState(["name": "remote"])
    try awareness.applyUpdate(remote.encodeUpdate())
    let provider = WebRTCProvider(
        "local-removal", doc: document, signaling: [], options: .init(awareness: awareness, iceServers: [])
    )
    let removals = WebRTCAwarenessRemovals()
    let observation = try awareness.observeUpdate { event in
        if case let .awarenessUpdate(change) = event { removals.append(change) }
    }
    defer { observation.cancel() }
    try await provider.connect()
    if destroy { await provider.destroy() } else { await provider.disconnect() }
    #expect(removals.values == [YAwarenessChange(added: [], updated: [], removed: [1], origin: "disconnect")])
    #expect(try awareness.localState() == nil)
    #expect(try awareness.state(for: 2) != nil)
    #expect(try awareness.encodeUpdate(for: [1]).data == Data([1, 1, 2, 4] + Array("null".utf8)))
    await provider.disconnect()
    #expect(removals.values.count == 1)
}

private final class WebRTCAwarenessRemovals: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [YAwarenessChange] = []

    var values: [YAwarenessChange] { lock.withLock { changes } }
    func append(_ change: YAwarenessChange) { lock.withLock { changes.append(change) } }
}
