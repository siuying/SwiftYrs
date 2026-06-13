import Foundation
import Testing
import SwiftYrs

@Test
func textObservationDeliversDeltasAndCanBeCancelled() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    var events: [YObservationEvent] = []

    let observation = try text.observe { event in
        events.append(event)
    }

    try doc.write { transaction in
        try transaction.insert("hello", into: text, at: 0, attributes: ["bold": .bool(true)])
    }

    #expect(events.count == 1)
    #expect(events[0].kind == "text")
    let firstDelta = try #require(events[0].array("delta").first as? [String: Any])
    #expect(firstDelta["kind"] as? String == "insert")
    #expect((firstDelta["insert"] as? [String: Any])?["value"] as? String == "hello")
    #expect(((firstDelta["attributes"] as? [String: Any])?["bold"] as? [String: Any])?["value"] as? Bool == true)

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
    var updateEvents: [YObservationEvent] = []
    var cleanupEvents: [YObservationEvent] = []
    var subdocEvents: [YObservationEvent] = []

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
    #expect(updateEvents[0].kind == "updateV1")
    #expect(!updateEvents[0].array("updateV1").isEmpty)
    #expect(cleanupEvents.count == 1)
    #expect(cleanupEvents[0].kind == "transactionCleanup")
    #expect(subdocEvents.count == 1)
    #expect(subdocEvents[0].kind == "subdocs")
    #expect(!subdocEvents[0].array("added").isEmpty)
    #expect(!subdocEvents[0].array("loaded").isEmpty)
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
    var arrayEvents: [YObservationEvent] = []
    var mapEvents: [YObservationEvent] = []
    var xmlEvents: [YObservationEvent] = []
    var xmlTextEvents: [YObservationEvent] = []

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
    #expect(arrayEvents[0].kind == "array")
    #expect(arrayEvents[0].array("delta").count == 1)
    #expect(mapEvents.count == 1)
    #expect(mapEvents[0].kind == "map")
    #expect((mapEvents[0].dictionary("keys")["status"] as? [String: Any])?["kind"] as? String == "insert")
    #expect(xmlEvents.count == 1)
    #expect(xmlEvents[0].kind == "xml")
    #expect(!xmlEvents[0].array("delta").isEmpty)
    #expect(xmlTextEvents.count == 1)
    #expect(xmlTextEvents[0].kind == "xmlText")
    #expect(!xmlTextEvents[0].array("delta").isEmpty)
    #expect(!xmlTextEvents[0].dictionary("keys").isEmpty)
}

@Test
func updateEventExposesTypedUpdateV1() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    var updates: [YUpdate] = []

    let observation = try doc.observeUpdates { event in
        if let update = event.updateV1 {
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
func nonUpdateEventHasNoTypedUpdate() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    var events: [YObservationEvent] = []

    let observation = try text.observe { events.append($0) }
    defer { observation.cancel() }

    try doc.write { transaction in
        try transaction.insert("hello", into: text, at: 0)
    }

    let event = try #require(events.first)
    #expect(event.updateV1 == nil)
}

@Test
func awarenessUpdateEventExposesChangedClientIDs() throws {
    let awareness = YAwareness(document: YDoc(clientID: 7))
    var changed: [[UInt64]] = []

    let observation = try awareness.observeUpdate { event in
        changed.append(event.changedAwarenessClientIDs)
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

    let task = Task<YObservationEvent?, Never> {
        for await event in stream {
            return event
        }
        return nil
    }

    try doc.write { transaction in
        try transaction.insert("async", into: text, at: 0)
    }

    let event = await task.value
    #expect(event?.kind == "text")
}
