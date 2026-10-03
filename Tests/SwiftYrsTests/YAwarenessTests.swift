import Foundation
import Testing
import SwiftYrs

private struct YjsAwarenessFixture: Decodable {
    let update: Data

    static func load(_ name: String) throws -> YjsAwarenessFixture {
        try loadFixture(name)
    }
}

@Test
func awarenessTracksLocalAndRemoteStatesThroughUpdates() throws {
    let local = YAwareness(document: YDoc(clientID: 1))
    let remote = YAwareness(document: YDoc(clientID: 2))

    try local.setLocalState([
        "name": "Ada",
        "cursor": ["index": 3]
    ])

    let localState = try #require(local.localState() as? [String: Any])
    #expect(localState["name"] as? String == "Ada")
    #expect((localState["cursor"] as? [String: Any])?["index"] as? Int == 3)

    try remote.applyUpdate(local.encodeUpdate())

    let remoteState = try #require(remote.state(for: 1) as? [String: Any])
    #expect(remoteState["name"] as? String == "Ada")
    #expect((remoteState["cursor"] as? [String: Any])?["index"] as? Int == 3)
    #expect(try remote.states().map(\.clientID) == [1])
}

@Test
func awarenessRemovalPropagatesWithExplicitClientUpdate() throws {
    let local = YAwareness(document: YDoc(clientID: 1))
    let remote = YAwareness(document: YDoc(clientID: 2))

    try local.setLocalState(["name": "Ada"])
    try remote.applyUpdate(local.encodeUpdate())
    _ = try #require(remote.state(for: 1) as? [String: Any])

    local.clearLocalState()
    try remote.applyUpdate(local.encodeUpdate(for: [1]))

    #expect(try remote.state(for: 1) == nil)
    #expect(try remote.states().isEmpty)
}

private enum AwarenessEventTag: Equatable {
    case update
    case change
}

private func tag(_ event: YEvent) -> AwarenessEventTag? {
    switch event {
    case .awarenessUpdate: return .update
    case .awarenessChange: return .change
    default: return nil
    }
}

private func awarenessChange(_ event: YEvent) -> YAwarenessChange? {
    switch event {
    case let .awarenessUpdate(change), let .awarenessChange(change): return change
    default: return nil
    }
}

@Test
func awarenessObservationDeliversUpdateAndChangeEvents() throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    var events: [YEvent] = []

    let update = try awareness.observeUpdate { events.append($0) }
    let change = try awareness.observeChange { events.append($0) }
    defer {
        update.cancel()
        change.cancel()
    }

    try awareness.setLocalState(["name": "Ada"])
    try awareness.setLocalState(["name": "Ada"])
    awareness.clearLocalState()

    #expect(events.compactMap(tag) == [.change, .update, .update, .change, .update])
    #expect(awarenessChange(events[0])?.added == [1])
    #expect(awarenessChange(events[2])?.updated == [1])
    #expect(awarenessChange(events[3])?.removed == [1])
}

@Test
func awarenessAsyncStreamYieldsEvents() async throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    let stream = try awareness.changeEvents()

    let task = Task<YEvent?, Never> {
        for await event in stream {
            return event
        }
        return nil
    }

    try awareness.setLocalState(["name": "Ada"])

    let event = await task.value
    #expect(tag(try #require(event)) == .change)
    #expect(awarenessChange(try #require(event))?.added == [1])
}

@Test
func awarenessCanApplyJavaScriptYjsFixture() throws {
    let fixture = try YjsAwarenessFixture.load("awareness-update")
    let awareness = YAwareness(document: YDoc(clientID: 12))

    try awareness.applyUpdate(YAwarenessUpdate(fixture.update))

    let state = try #require(awareness.state(for: 11) as? [String: Any])
    #expect(state["name"] as? String == "JS")
    #expect((state["cursor"] as? [String: Any])?["index"] as? Int == 7)
}

@Test
func awarenessRenewsAtHalfTimeoutWithoutChangingState() throws {
    let clock = AwarenessTestClock()
    let local = YAwareness(document: YDoc(clientID: 1), now: { clock.now() })
    let peer = YAwareness(document: YDoc(clientID: 2))
    try local.setLocalState(["name": "Ada"])
    let original = try local.encodeUpdate()
    try peer.applyUpdate(original)
    var updates: [YEvent] = []
    var changes: [YEvent] = []
    let updateObservation = try local.observeUpdate { updates.append($0) }
    let changeObservation = try local.observeChange { changes.append($0) }
    defer {
        updateObservation.cancel()
        changeObservation.cancel()
    }

    clock.set(.milliseconds(14_999))
    try local.checkTimeouts()
    #expect(updates.isEmpty)
    clock.set(.seconds(15))
    try local.checkTimeouts()
    #expect(updates.count == 1)
    #expect(awarenessChange(updates[0])?.updated == [1])
    #expect(changes.isEmpty)
    let renewed = try local.encodeUpdate()
    #expect(renewed != original)
    try peer.applyUpdate(renewed)
    #expect(try (peer.state(for: 1) as? [String: Any])?["name"] as? String == "Ada")
    try local.checkTimeouts()
    #expect(updates.count == 1)
}

@Test
func awarenessExpiresRemoteStatesWithTimeoutOriginAndPreservesClocks() throws {
    let clock = AwarenessTestClock()
    let local = YAwareness(document: YDoc(clientID: 1), now: { clock.now() })
    let peer = YAwareness(document: YDoc(clientID: 2))
    let other = YAwareness(document: YDoc(clientID: 3))
    try peer.setLocalState(["name": "peer"])
    try other.setLocalState(["name": "other"])
    try local.applyUpdate(peer.encodeUpdate())
    try local.applyUpdate(other.encodeUpdate())
    var events: [YEvent] = []
    let update = try local.observeUpdate { events.append($0) }
    let change = try local.observeChange { events.append($0) }
    defer {
        update.cancel()
        change.cancel()
    }

    clock.set(.milliseconds(29_999))
    try local.checkTimeouts()
    #expect(events.isEmpty)
    clock.set(.seconds(30))
    try local.checkTimeouts()
    #expect(try local.states().isEmpty)
    #expect(events.compactMap(tag) == [.change, .update])
    for event in events {
        #expect(awarenessChange(event)?.removed.sorted() == [2, 3])
        #expect(awarenessChange(event)?.origin == "timeout")
    }
    try local.checkTimeouts()
    #expect(events.count == 2)

    try peer.setLocalState(["name": "peer"])
    try local.applyUpdate(peer.encodeUpdate())
    #expect(try local.state(for: 2) != nil)
    #expect(awarenessChange(try #require(events.last))?.origin == nil)
}

@Test
func awarenessOnlyAcceptedRemoteUpdatesRefreshLifetime() throws {
    let clock = AwarenessTestClock()
    let local = YAwareness(document: YDoc(clientID: 1), now: { clock.now() })
    let peer = YAwareness(document: YDoc(clientID: 2))
    try peer.setLocalState(["name": "peer"])
    let original = try peer.encodeUpdate()
    try local.applyUpdate(original)

    clock.set(.seconds(20))
    try local.applyUpdate(original)
    clock.set(.seconds(30))
    try local.checkTimeouts()
    #expect(try local.state(for: 2) == nil)

    try peer.setLocalState(["name": "peer"])
    try local.applyUpdate(peer.encodeUpdate())
    clock.set(.seconds(50))
    try peer.setLocalState(["name": "peer"])
    try local.applyUpdate(peer.encodeUpdate())
    clock.set(.seconds(60))
    try local.checkTimeouts()
    #expect(try local.state(for: 2) != nil)
    clock.set(.seconds(80))
    try local.checkTimeouts()
    #expect(try local.state(for: 2) == nil)
}

@Test
func awarenessDoesNotRenewNullLocalState() throws {
    let clock = AwarenessTestClock()
    let local = YAwareness(document: YDoc(clientID: 1), now: { clock.now() })
    try local.setLocalState(["name": "Ada"])
    try local.setLocalStateJSON(Data("null".utf8))
    var events: [YEvent] = []
    let observation = try local.observeUpdate { events.append($0) }
    defer { observation.cancel() }
    clock.set(.seconds(60))
    try local.checkTimeouts()
    #expect(try local.localState() == nil)
    #expect(events.isEmpty)
}

private final class AwarenessTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero

    func now() -> Duration { lock.withLock { time } }
    func set(_ time: Duration) { lock.withLock { self.time = time } }
}

@Test
func awarenessTimeoutCallbacksCanRestorePeerWithoutLosingLifetimeOrLeakingOrigin() throws {
    let clock = AwarenessTestClock()
    let local = YAwareness(document: YDoc(clientID: 1), now: { clock.now() })
    let peer = YAwareness(document: YDoc(clientID: 2))
    try peer.setLocalState(["name": "peer"])
    try local.applyUpdate(peer.encodeUpdate())
    var restored = false
    var localUpdates: [YAwarenessChange] = []
    let update = try local.observeUpdate { event in
        if case let .awarenessUpdate(change) = event, change.changed.contains(1) {
            localUpdates.append(change)
        }
    }
    let change = try local.observeChange { event in
        guard case let .awarenessChange(change) = event,
              change.origin == "timeout", !restored else { return }
        restored = true
        do {
            try local.setLocalState(["name": "local"])
            try peer.setLocalState(["name": "peer"])
            try local.applyUpdate(peer.encodeUpdate())
        } catch {
            Issue.record("Failed to restore awareness in timeout callback: \(error)")
        }
    }
    defer {
        update.cancel()
        change.cancel()
    }

    clock.set(.seconds(30))
    try local.checkTimeouts()
    #expect(restored)
    #expect(try local.state(for: 2) != nil)
    #expect(localUpdates.count == 1)
    #expect(localUpdates.allSatisfy { $0.origin == nil })
    clock.set(.seconds(60))
    try local.checkTimeouts()
    #expect(try local.state(for: 2) == nil)
    #expect(localUpdates.count == 2)
    #expect(localUpdates.allSatisfy { $0.origin == nil })
}

@Test(arguments: [false, true])
func awarenessTimeoutUpdateCallbackCanRestorePeerUntilNextTimeout(usingSyncProtocol: Bool) throws {
    let clock = AwarenessTestClock()
    let local = YAwareness(document: YDoc(clientID: 1), now: { clock.now() })
    let peer = YAwareness(document: YDoc(clientID: 2))
    try peer.setLocalState(["name": "peer"])
    try local.applyUpdate(peer.encodeUpdate())
    var restored = false
    let observation = try local.observeUpdate { event in
        guard case let .awarenessUpdate(change) = event,
              change.origin == "timeout", !restored else { return }
        restored = true
        do {
            try peer.setLocalState(["name": "peer"])
            if usingSyncProtocol {
                let payload = try YSyncMessage.awareness(peer.encodeUpdate()).payload
                _ = try YSyncProtocol.handle(payload, awareness: local)
            } else {
                try local.applyUpdate(peer.encodeUpdate())
            }
        } catch {
            Issue.record("Failed to restore awareness in update callback: \(error)")
        }
    }
    defer { observation.cancel() }
    clock.set(.seconds(30))
    try local.checkTimeouts()
    #expect(restored)
    clock.set(.seconds(59))
    try local.checkTimeouts()
    #expect(try local.state(for: 2) != nil)
    clock.set(.seconds(60))
    try local.checkTimeouts()
    #expect(try local.state(for: 2) == nil)
}
