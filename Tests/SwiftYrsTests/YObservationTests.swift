import Foundation
import Testing
import SwiftYrs

private extension YEvent {
    var shared: YSharedEvent? {
        if case let .shared(value) = self { return value }
        return nil
    }

    var update: YUpdate? {
        if case let .update(value) = self { return value }
        return nil
    }
}

private extension YTextDeltaOperation {
    var insert: (value: YValue, attributes: YAttributes)? {
        if case let .insert(value, attributes) = self { return (value, attributes) }
        return nil
    }
}

@Test
func textObservationDeliversDeltasAndCanBeCancelled() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    var events: [YEvent] = []

    let observation = try text.observe { event in
        events.append(event)
    }

    try doc.write { transaction in
        try transaction.insert("hello", into: text, at: 0, attributes: ["bold": .bool(true)])
    }

    #expect(events.count == 1)
    let shared = try #require(events.first?.shared)
    #expect(shared.target == .text)
    let insert = try #require(shared.delta.first?.insert)
    #expect(insert.value == .string("hello"))
    #expect(insert.attributes["bold"] == .bool(true))

    observation.cancel()

    try doc.write { transaction in
        try transaction.insert("!", into: text, at: 5)
    }

    #expect(events.count == 1)
}

@Test
func documentObservationDeliversUpdateCleanupAndSubdocEvents() throws {
    let doc = YDoc()
    let map = try doc.map(named: "subdocs")
    var updateEvents: [YEvent] = []
    var cleanupEvents: [YEvent] = []
    var subdocEvents: [YEvent] = []

    let updates = try doc.observeUpdates { updateEvents.append($0) }
    let cleanup = try doc.observeTransactionCleanup { cleanupEvents.append($0) }
    let subdocs = try doc.observeSubdocs { subdocEvents.append($0) }
    defer {
        updates.cancel()
        cleanup.cancel()
        subdocs.cancel()
    }

    try doc.write { transaction in
        _ = try transaction.setNewSubdoc(forKey: "child", in: map)
        try transaction.loadSubdoc(forKey: "child", in: map)
    }

    #expect(updateEvents.count == 1)
    #expect(!(try #require(updateEvents.first?.update)).data.isEmpty)
    #expect(cleanupEvents.count == 1)
    if case .transactionCleanup = cleanupEvents[0] {} else {
        Issue.record("expected transactionCleanup, got \(cleanupEvents[0])")
    }
    #expect(subdocEvents.count == 1)
    guard case let .subdocs(added, _, loaded) = subdocEvents[0] else {
        Issue.record("expected subdocs, got \(subdocEvents[0])")
        return
    }
    #expect(!added.isEmpty)
    #expect(!loaded.isEmpty)
}

@Test
func sharedTypeObservationDeliversKeyPathAndXmlChanges() throws {
    let doc = YDoc()
    let array = try doc.array(named: "items")
    let map = try doc.map(named: "meta")
    let fragment = try doc.xmlFragment(named: "article")
    let xmlText = try doc.write { transaction in
        try transaction.insertText(into: fragment, at: 0)
    }
    var arrayEvents: [YEvent] = []
    var mapEvents: [YEvent] = []
    var xmlEvents: [YEvent] = []
    var xmlTextEvents: [YEvent] = []

    let arrayObservation = try array.observe { arrayEvents.append($0) }
    let mapObservation = try map.observe { mapEvents.append($0) }
    let xmlObservation = try fragment.observe { xmlEvents.append($0) }
    var xmlTextObservation: Observation?
    defer {
        arrayObservation.cancel()
        mapObservation.cancel()
        xmlObservation.cancel()
        xmlTextObservation?.cancel()
    }

    try doc.write { transaction in
        try transaction.insert(.string("a"), into: array, at: 0)
        try transaction.set(.string("draft"), forKey: "status", in: map)
        _ = try transaction.insertElement(named: "p", into: fragment, at: 1)
        xmlTextObservation = try xmlText.observe { xmlTextEvents.append($0) }
        try transaction.insert("caption", into: xmlText, at: 0)
        try transaction.setAttribute(.string("plain"), forKey: "kind", in: xmlText)
    }

    #expect(arrayEvents.count == 1)
    let arrayShared = try #require(arrayEvents.first?.shared)
    #expect(arrayShared.target == .array)
    #expect(arrayShared.delta.count == 1)

    #expect(mapEvents.count == 1)
    let mapShared = try #require(mapEvents.first?.shared)
    #expect(mapShared.target == .map)
    #expect(mapShared.keys["status"] == .inserted(.string("draft")))

    #expect(xmlEvents.count == 1)
    let xmlShared = try #require(xmlEvents.first?.shared)
    #expect(xmlShared.target == .xml)
    #expect(!xmlShared.delta.isEmpty)

    #expect(xmlTextEvents.count == 1)
    let xmlTextShared = try #require(xmlTextEvents.first?.shared)
    #expect(xmlTextShared.target == .xmlText)
    #expect(!xmlTextShared.delta.isEmpty)
    #expect(!xmlTextShared.keys.isEmpty)
}

@Test
func updateEventExposesTypedUpdateV1() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    var updates: [YUpdate] = []

    let observation = try doc.observeUpdates { event in
        if case let .update(update) = event {
            updates.append(update)
        }
    }
    defer { observation.cancel() }

    try doc.write { transaction in
        try transaction.insert("hello", into: text, at: 0)
    }

    let update = try #require(updates.first)
    let replica = YDoc()
    try replica.apply(update)
    let replicaText = try replica.text(named: "body")
    let replicated = try replica.read { try $0.string(from: replicaText) }
    #expect(replicated == "hello")
}

@Test
func sharedEventIsNotAnUpdateEvent() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    var events: [YEvent] = []

    let observation = try text.observe { events.append($0) }
    defer { observation.cancel() }

    try doc.write { transaction in
        try transaction.insert("hello", into: text, at: 0)
    }

    let event = try #require(events.first)
    #expect(event.update == nil)
    #expect(event.shared != nil)
}

@Test
func awarenessUpdateEventExposesChangedClientIDs() throws {
    let awareness = YAwareness(document: YDoc(clientID: 7))
    var changed: [[UInt64]] = []

    let observation = try awareness.observeUpdate { event in
        if case let .awarenessUpdate(change) = event {
            changed.append(change.changed)
        }
    }
    defer { observation.cancel() }

    try awareness.setLocalState(["name": "Ada"])

    #expect(changed.first == [7])
}

@Test
func asyncObservationStreamYieldsEventsAndTerminates() async throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    let stream = try text.events()

    let task = Task<YEvent?, Never> {
        for await event in stream {
            return event
        }
        return nil
    }

    try doc.write { transaction in
        try transaction.insert("async", into: text, at: 0)
    }

    let event = await task.value
    #expect(event?.shared?.target == .text)
}
