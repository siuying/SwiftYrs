import Foundation
import SwiftYrsTestSupport
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
        #expect(awarenessChange(event)?.origin == YAwarenessChange.timeoutOrigin)
    }
    try local.checkTimeouts()
    #expect(events.count == 2)

    try peer.setLocalState(["name": "peer"])
    try local.applyUpdate(peer.encodeUpdate())
    #expect(try local.state(for: 2) != nil)
    #expect(awarenessChange(try #require(events.last))?.origin == nil)
}

@Test(arguments: ["true", "5"])
func awarenessExpiresRemoteScalarJSONState(json: String) throws {
    let clock = AwarenessTestClock()
    let local = YAwareness(document: YDoc(clientID: 1), now: { clock.now() })
    let peer = YAwareness(document: YDoc(clientID: 2))
    try peer.setLocalStateJSON(Data(json.utf8))
    try local.applyUpdate(peer.encodeUpdate())
    #expect(try local.states().map(\.clientID) == [2])
    var changes: [YAwarenessChange] = []
    let observation = try local.observeChange { event in
        if case let .awarenessChange(change) = event { changes.append(change) }
    }
    defer { observation.cancel() }

    clock.set(.milliseconds(29_999))
    try local.checkTimeouts()
    #expect(changes.isEmpty)
    clock.set(.seconds(30))
    try local.checkTimeouts()
    #expect(try local.states().isEmpty)
    #expect(changes.count == 1)
    #expect(changes.first?.removed == [2])
    #expect(changes.first?.origin == YAwarenessChange.timeoutOrigin)
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
func awarenessArrivalCallbackCannotShiftRemoteExpiryTimestamp() throws {
    let clock = AwarenessTestClock()
    let awareness = YAwareness(document: YDoc(clientID: 1), now: { clock.now() })
    let peer = YAwareness(document: YDoc(clientID: 2))
    try peer.setLocalState(["name": "peer"])
    var expired = false
    let observation = try awareness.observeChange { event in
        guard case let .awarenessChange(change) = event else { return }
        if change.added == [2] { clock.set(.seconds(30)) }
        if change.removed == [2] { expired = true }
    }
    defer { observation.cancel() }
    try awareness.applyUpdate(peer.encodeUpdate())
    try awareness.checkTimeouts()
    #expect(expired)
    #expect(try awareness.state(for: 2) == nil)
}

@Test
func awarenessDoesNotRenewNullLocalState() throws {
    let clock = AwarenessTestClock()
    let local = YAwareness(document: YDoc(clientID: 1), now: { clock.now() })
    try local.setLocalState(["name": "Ada"])
    local.clearLocalState()
    var events: [YEvent] = []
    let observation = try local.observeUpdate { events.append($0) }
    defer { observation.cancel() }
    clock.set(.seconds(60))
    try local.checkTimeouts()
    #expect(try local.localState() == nil)
    #expect(events.isEmpty)
}

@Test
func awarenessDoesNotRenewRawNullJSON() throws {
    let clock = AwarenessTestClock()
    let local = YAwareness(document: YDoc(clientID: 1), now: { clock.now() })
    try local.setLocalState(["name": "Ada"])
    try local.setLocalStateJSON(Data("null".utf8))
    let before = try local.encodeUpdate()
    clock.set(.seconds(60))
    try local.checkTimeouts()
    #expect(try local.encodeUpdate() == before)
}

@Test
func awarenessConcurrentRenewalNeverOverwritesLatestLocalState() async throws {
    let clock = AdvancingAwarenessClock()
    let local = YAwareness(document: YDoc(clientID: 1), now: { clock.now() })
    let remote = YAwareness(document: YDoc(clientID: 2))
    let iterations = 2_000
    let received = AwarenessUpdateCounter()
    let observation = try local.observeUpdate { _ in received.increment() }
    defer { observation.cancel() }
    let writer = Task {
        try await onTestThread {
            for version in 1...iterations {
                try local.setLocalState(["version": version])
                #expect(try (local.localState() as? [String: Any])?["version"] as? Int == version)
            }
        }
    }
    let receiver = Task {
        try await onTestThread {
            for version in 1...iterations {
                try remote.setLocalState(["version": version])
                try local.applyUpdate(remote.encodeUpdate())
                try local.checkTimeouts()
            }
        }
    }
    let otherProvider = Task {
        try await onTestThread {
            for _ in 1...iterations {
                try local.checkTimeouts()
                _ = try local.encodeUpdate()
            }
        }
    }
    let subscriptions = Task {
        try await onTestThread {
            for _ in 1...iterations {
                let observation = try local.observeUpdate { _ in }
                observation.cancel()
            }
        }
    }
    try await writer.value
    try await receiver.value
    try await otherProvider.value
    try await subscriptions.value
    #expect(try (local.localState() as? [String: Any])?["version"] as? Int == iterations)
    let before = received.count()
    try local.setLocalState(["version": iterations])
    #expect(received.count() == before + 1)
}

@Test
func awarenessCallbacksCanReenterFromAnotherThread() async throws {
    try await onTestThread {
        let awareness = YAwareness(document: YDoc(clientID: 1))
        let queue = DispatchQueue(label: "awareness-callback-reentry")
        var reentered = false
        let observation = try awareness.observeChange { event in
            guard case let .awarenessChange(change) = event, !change.added.isEmpty else { return }
            do {
                try queue.sync {
                    try awareness.setLocalState(["name": "updated"])
                }
                reentered = true
            } catch {
                Issue.record("Failed to re-enter awareness from another thread: \(error)")
            }
        }
        defer { observation.cancel() }
        try awareness.setLocalState(["name": "initial"])
        #expect(reentered)
        #expect(try (awareness.localState() as? [String: Any])?["name"] as? String == "updated")
    }
}

@Test(arguments: [false, true])
func awarenessCancellationSkipsQueuedCallbacksWithoutWaitingForDelivery(removingState: Bool) async throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    if removingState { try awareness.setLocalState(["name": "Ada"]) }
    let entered = AsyncStream.makeStream(of: Void.self)
    let release = DispatchSemaphore(value: 0)
    let changes = try awareness.observeChange { _ in
        entered.continuation.yield(())
        release.wait()
    }
    let received = AwarenessUpdateCounter()
    let updates = try awareness.observeUpdate { _ in received.increment() }
    defer {
        release.signal()
        changes.cancel()
        updates.cancel()
    }
    let completed = AsyncStream.makeStream(of: Result<Void, Error>.self)
    Thread {
        completed.continuation.yield(Result {
            if removingState {
                awareness.removeStates(for: [1], origin: "caller")
            } else {
                try awareness.setLocalState(["name": "Ada"])
            }
        })
        completed.continuation.finish()
    }.start()
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    updates.cancel()
    release.signal()
    var completion = completed.stream.makeAsyncIterator()
    let result = try #require(await completion.next())
    try result.get()
    #expect(received.count() == 0)
}

private final class AwarenessUpdateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    func count() -> Int { lock.withLock { value } }
}

private final class AdvancingAwarenessClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero

    func now() -> Duration {
        lock.withLock {
            time += .seconds(15)
            return time
        }
    }
}

private final class AwarenessTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero

    func now() -> Duration { lock.withLock { time } }
    func set(_ time: Duration) { lock.withLock { self.time = time } }
}

@Test
func awarenessRemovalKeepsRemoteClockAndAcceptsNextUpdate() throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    let peer = YAwareness(document: YDoc(clientID: 2))
    try peer.setLocalState(["name": "peer"])
    try awareness.applyUpdate(peer.encodeUpdate())
    awareness.removeState(for: 2)
    // One entry: client 2, clock 1, JSON null.
    #expect(try awareness.encodeUpdate(for: [2]).data == Data([1, 2, 1, 4] + Array("null".utf8)))
    try peer.setLocalState(["name": "returned"])
    try awareness.applyUpdate(peer.encodeUpdate())
    #expect(try (awareness.state(for: 2) as? [String: Any])?["name"] as? String == "returned")
}

@Test
func awarenessConcurrentBatchRemovalPreservesLatestRemoteClock() async throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    let peer = YAwareness(document: YDoc(clientID: 2))
    var updates: [YAwarenessUpdate] = []
    for version in 1...200 {
        try peer.setLocalState(["version": version])
        updates.append(try peer.encodeUpdate())
    }
    let finished = AsyncStream.makeStream(of: Result<Void, Error>.self)
    Thread { [updates] in
        finished.continuation.yield(Result {
            for update in updates { try awareness.applyUpdate(update) }
        })
    }.start()
    Thread {
        for _ in 1...200 { awareness.removeStates(for: [2, 99, 2], origin: "caller") }
        finished.continuation.yield(.success(()))
    }.start()
    for _ in 0..<2 { try await nextTestEvent(finished.stream).get() }
    finished.continuation.finish()
    awareness.removeStates(for: [2], origin: "caller")
    #expect(try awareness.encodeUpdate(for: [2]).data == Data([1, 2, 0xc8, 1, 4] + Array("null".utf8)))
    #expect(throws: YError.self) { try awareness.encodeUpdate(for: [99]) }
    try peer.setLocalState(["version": 201])
    try awareness.applyUpdate(peer.encodeUpdate())
    #expect(try (awareness.state(for: 2) as? [String: Any])?["version"] as? Int == 201)
}

@Test
func awarenessRemovalOfUnknownOrAlreadyRemovedClientDoesNothing() throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    var events: [YEvent] = []
    let update = try awareness.observeUpdate { events.append($0) }
    let change = try awareness.observeChange { events.append($0) }
    defer { update.cancel(); change.cancel() }

    awareness.removeState(for: 99)
    awareness.removeStates(for: [1])
    #expect(events.isEmpty)
    #expect(throws: YError.self) { try awareness.encodeUpdate(for: [99]) }
    #expect(throws: YError.self) { try awareness.encodeUpdate(for: [1]) }

    try awareness.setLocalState(["name": "local"])
    awareness.removeState(for: 1)
    let removed = try awareness.encodeUpdate(for: [1])
    events.removeAll()
    awareness.removeState(for: 1)
    awareness.removeStates(for: [1])
    #expect(events.isEmpty)
    #expect(try awareness.encodeUpdate(for: [1]) == removed)
}

@Test(arguments: [false, true])
func awarenessLocalMutationsUseLocalOrigin(json: Bool) throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    var events: [YEvent] = []
    let update = try awareness.observeUpdate { events.append($0) }
    let change = try awareness.observeChange { events.append($0) }
    defer { update.cancel(); change.cancel() }
    for index in 0..<2 {
        events.removeAll()
        if json { try awareness.setLocalStateJSON(Data("{\"name\":\"local\"}".utf8)) }
        else { try awareness.setLocalState(["name": "local"]) }
        #expect(events.compactMap(tag) == (index == 0 ? [.change, .update] : [.update]))
        #expect(events.compactMap(awarenessChange).allSatisfy { $0.origin == "local" })
    }
    events.removeAll()
    if json { try awareness.setLocalStateJSON(Data("null".utf8)) }
    else { awareness.clearLocalState() }
    #expect(events.compactMap(tag) == [.change, .update])
    #expect(events.compactMap(awarenessChange).allSatisfy { $0.origin == "local" })
}

@Test(arguments: [false, true])
func awarenessSettingLocalNullAlwaysAdvancesClockAndEmits(initiallyPresent: Bool) throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    if initiallyPresent { try awareness.setLocalState(["name": "local"]) }
    var events: [YEvent] = []
    let update = try awareness.observeUpdate { events.append($0) }
    let change = try awareness.observeChange { events.append($0) }
    defer { update.cancel(); change.cancel() }

    for index in 0..<4 {
        events.removeAll()
        switch index {
        case 1: try awareness.setLocalStateJSON(Data(" \nnull\t".utf8))
        case 2: try awareness.setLocalState(NSNull())
        default: awareness.clearLocalState()
        }
        let clock = UInt8(index + (initiallyPresent ? 2 : 1))
        #expect(try awareness.encodeUpdate(for: [1]).data == Data([1, 1, clock, 4] + Array("null".utf8)))
        #expect(try awareness.localState() == nil)
        #expect(try awareness.states().isEmpty)
        #expect(events.compactMap(tag) == [.change, .update])
        #expect(events.compactMap(awarenessChange) == Array(repeating:
            YAwarenessChange(added: [], updated: [], removed: [1], origin: "local"), count: 2
        ))

        events.removeAll()
        awareness.removeStates(for: [1], origin: "removal")
        #expect(events.isEmpty)
        #expect(try awareness.encodeUpdate(for: [1]).data == Data([1, 1, clock, 4] + Array("null".utf8)))
    }
}

@Test
func awarenessClearingUninitializedLocalStateEmitsWithOnlyUpdateObserver() throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    var events: [YEvent] = []
    let observation = try awareness.observeUpdate { events.append($0) }
    defer { observation.cancel() }
    awareness.clearLocalState()
    #expect(events.compactMap(awarenessChange) == [
        YAwarenessChange(added: [], updated: [], removed: [1], origin: "local")
    ])
}

@Test
func awarenessRemovalOfLocalClientIncrementsClockAndEmits() throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    try awareness.setLocalState(["name": "local"])
    var events: [YEvent] = []
    let update = try awareness.observeUpdate { events.append($0) }
    let change = try awareness.observeChange { events.append($0) }
    defer { update.cancel(); change.cancel() }
    awareness.removeState(for: 1)
    #expect(try awareness.encodeUpdate(for: [1]).data == Data([1, 1, 2, 4] + Array("null".utf8)))
    #expect(events.compactMap(tag) == [.change, .update])
    #expect(events.compactMap(awarenessChange).allSatisfy { $0.removed == [1] })
}

@Test(arguments: [false, true])
func awarenessBatchRemovalEmitsOnceWithCallerOrigin(includingLocal: Bool) throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    let peer = YAwareness(document: YDoc(clientID: 2))
    let other = YAwareness(document: YDoc(clientID: 3))
    try awareness.setLocalState(["name": "local"])
    try peer.setLocalState(["name": "peer"])
    try other.setLocalState(["name": "other"])
    try awareness.applyUpdate(peer.encodeUpdate())
    try awareness.applyUpdate(other.encodeUpdate())
    let ids: [UInt64] = includingLocal ? [2, 1, 3] : [2, 3]
    var events: [YEvent] = []
    var sawRemovedStates = false
    let update = try awareness.observeUpdate { events.append($0) }
    let change = try awareness.observeChange {
        events.append($0)
        sawRemovedStates = ids.allSatisfy { (try? awareness.state(for: $0)) == nil }
    }
    defer { update.cancel(); change.cancel() }
    awareness.removeStates(for: ids + [2, 99], origin: "caller")
    #expect(sawRemovedStates)
    #expect(events.compactMap(tag) == [.change, .update])
    for event in events {
        #expect(awarenessChange(event) == YAwarenessChange(added: [], updated: [], removed: ids, origin: "caller"))
    }
    #expect(try awareness.encodeUpdate(for: [2]).data == Data([1, 2, 1, 4] + Array("null".utf8)))
    #expect(try awareness.encodeUpdate(for: [3]).data == Data([1, 3, 1, 4] + Array("null".utf8)))
    if includingLocal {
        #expect(try awareness.encodeUpdate(for: [1]).data == Data([1, 1, 2, 4] + Array("null".utf8)))
    }
    awareness.removeStates(for: ids, origin: "again")
    #expect(events.count == 2)
    try awareness.setLocalState(["name": "returned"])
    #expect(awarenessChange(try #require(events.last))?.origin == "local")
}

@Test
func awarenessRemovalOriginDoesNotLeakIntoNestedMutation() throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    let peer = YAwareness(document: YDoc(clientID: 2))
    try peer.setLocalState(["name": "peer"])
    try awareness.applyUpdate(peer.encodeUpdate())
    var events: [YAwarenessChange] = []
    let queue = DispatchQueue(label: "awareness-removal-reentry")
    let update = try awareness.observeUpdate {
        if case let .awarenessUpdate(change) = $0 { events.append(change) }
    }
    let change = try awareness.observeChange {
        guard case let .awarenessChange(change) = $0, change.removed == [2] else { return }
        do { try queue.sync { try awareness.setLocalState(["name": "nested"]) } }
        catch { Issue.record("Failed nested mutation: \(error)") }
    }
    defer { update.cancel(); change.cancel() }
    awareness.removeState(for: 2, origin: "caller")
    #expect(events.first?.removed == [2])
    #expect(events.first?.origin == "caller")
    #expect(events.last?.added == [1])
    #expect(events.last?.origin == "local")
    awareness.clearLocalState(origin: "local removal")
    #expect(events.last?.origin == "local removal")
}

@Test
func awarenessAppliedRemovalUsesCallerOrigin() throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    let peer = YAwareness(document: YDoc(clientID: 2))
    try peer.setLocalState(["name": "peer"])
    try awareness.applyUpdate(peer.encodeUpdate())
    var events: [YEvent] = []
    let update = try awareness.observeUpdate { events.append($0) }
    let change = try awareness.observeChange { events.append($0) }
    defer { update.cancel(); change.cancel() }
    let removal = YAwarenessUpdate(Data([1, 2, 1, 4] + Array("null".utf8)))
    try awareness.applyUpdate(removal, origin: "wire")
    #expect(events.compactMap(tag) == [.change, .update])
    #expect(events.compactMap(awarenessChange).allSatisfy { $0.removed == [2] && $0.origin == "wire" })
    try peer.setLocalState(["name": "returned"])
    try awareness.applyUpdate(peer.encodeUpdate())
    #expect(awarenessChange(try #require(events.last))?.origin == nil)
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
              change.origin == YAwarenessChange.timeoutOrigin, !restored else { return }
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
    #expect(localUpdates.allSatisfy { $0.origin == "local" })
    clock.set(.seconds(60))
    try local.checkTimeouts()
    #expect(try local.state(for: 2) == nil)
    #expect(localUpdates.count == 2)
    #expect(localUpdates.allSatisfy { $0.origin == "local" })
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
              change.origin == YAwarenessChange.timeoutOrigin, !restored else { return }
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

