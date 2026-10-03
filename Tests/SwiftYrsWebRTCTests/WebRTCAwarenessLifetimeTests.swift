import Foundation
import Testing
import SwiftYrs
import SwiftYrsWebRTC

@Test
func webRTCAwarenessRenewsExpiresAndStopsWithProviderLifecycle() async throws {
    let clock = WebRTCAwarenessClock()
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
        options: .init(awareness: awareness, iceServers: [])
    )
    var updates = try awareness.updateEvents().makeAsyncIterator()
    var changes = try awareness.changeEvents().makeAsyncIterator()
    let received = WebRTCAwarenessUpdates()
    let observation = try awareness.observeUpdate { _ in received.increment() }
    defer { observation.cancel() }
    try await provider.connect()
    clock.set(.seconds(15))
    if case let .awarenessUpdate(change) = await updates.next() {
        #expect(change.updated == [301])
    } else {
        Issue.record("Expected WebRTC awareness renewal")
    }

    clock.set(.seconds(30))
    if case let .awarenessChange(change) = await changes.next() {
        #expect(change.removed == [302])
        #expect(change.origin == YAwarenessChange.timeoutOrigin)
    } else {
        Issue.record("Expected WebRTC awareness expiry")
    }
    await provider.disconnect()
    let stopped = received.count()
    clock.set(.seconds(60))
    try await Task.sleep(for: .milliseconds(30))
    #expect(received.count() == stopped)

    try await provider.connect()
    await provider.destroy()
    let destroyed = received.count()
    clock.set(.seconds(120))
    try await Task.sleep(for: .milliseconds(30))
    #expect(received.count() == destroyed)
}

extension RealNetworkE2E {
    @Suite(.serialized)
    struct WebRTCAwarenessLifetimeTests {
        @Test
        func idleAwarenessRenewalReachesSwiftPeerOverDataChannel() async throws {
            let server = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
            defer { server.stop() }
            let ready = try await server.waitForLine("signaling server ready") { $0["type"] as? String == "ready" }
            let port = try #require(ready["port"] as? Int)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
            let clock = WebRTCAwarenessClock()
            let document = YDoc(clientID: 303)
            let awareness = YAwareness(
                document: document, timing: .init(checkInterval: .milliseconds(5)), now: { clock.now() }
            )
            try awareness.setLocalState(["name": "idle"])
            let provider = WebRTCProvider(
                "awareness-renewal", doc: document, signaling: [url], options: .init(awareness: awareness, iceServers: [])
            )
            let peerDocument = YDoc(clientID: 304)
            let peerAwareness = YAwareness(document: peerDocument)
            let peer = WebRTCProvider(
                "awareness-renewal", doc: peerDocument, signaling: [url], options: .init(awareness: peerAwareness, iceServers: [])
            )
            try await withE2ETeardown([provider, peer]) {
                try await provider.connect()
                try await peer.connect()
                try await e2eEventually("initial awareness reaches Swift peer", timeout: .seconds(10)) {
                    try (peerAwareness.state(for: 303) as? [String: Any])?["name"] as? String == "idle"
                }
                let received = WebRTCAwarenessUpdates()
                let observation = try peerAwareness.observeUpdate { event in
                    if case let .awarenessUpdate(change) = event, change.updated.contains(303) {
                        received.increment()
                    }
                }
                defer { observation.cancel() }
                clock.set(.seconds(15))
                try await e2eEventually("idle awareness renewal reaches Swift peer", timeout: .seconds(5)) {
                    received.count() > 0
                }
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
