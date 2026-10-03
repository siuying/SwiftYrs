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
        #expect(change.origin == "timeout")
    } else {
        Issue.record("Expected WebRTC awareness expiry")
    }
    await provider.disconnect()
    let stopped = try awareness.encodeUpdate()
    clock.set(.seconds(60))
    try await Task.sleep(for: .milliseconds(30))
    #expect(try awareness.encodeUpdate() == stopped)

    try await provider.connect()
    await provider.destroy()
    let destroyed = try awareness.encodeUpdate()
    clock.set(.seconds(120))
    try await Task.sleep(for: .milliseconds(30))
    #expect(try awareness.encodeUpdate() == destroyed)
}

private final class WebRTCAwarenessClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero

    func now() -> Duration { lock.withLock { time } }
    func set(_ time: Duration) { lock.withLock { self.time = time } }
}
