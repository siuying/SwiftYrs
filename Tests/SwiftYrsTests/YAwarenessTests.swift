import Foundation
import Testing
import SwiftYrs

private struct YjsAwarenessFixture: Decodable {
    let update: Data

    private enum CodingKeys: String, CodingKey {
        case update
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .update)
        guard let data = Data(base64Encoded: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .update,
                in: container,
                debugDescription: "Expected base64-encoded bytes"
            )
        }
        update = data
    }

    static func load(_ name: String) throws -> YjsAwarenessFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(forResource: name, withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(YjsAwarenessFixture.self, from: data)
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
