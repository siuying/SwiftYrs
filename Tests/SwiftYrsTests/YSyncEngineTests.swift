import Foundation
import Testing
import SwiftYrs

@Test
func syncEngineRepliesToStepOneThroughSink() throws {
    let sourceDoc = YDoc(clientID: 1)
    let sourceText = try sourceDoc.text(named: "body")
    try sourceDoc.write { transaction in
        try transaction.insert("hello", into: sourceText, at: 0)
    }

    let remoteDoc = YDoc(clientID: 2)
    var sent: [YSyncMessage] = []
    let engine = YSyncEngine(doc: sourceDoc, awareness: nil) { message in
        sent.append(message)
    }

    let result = try engine.handle(.syncStep1(remoteDoc.stateVector()))

    #expect(result.didSync == false)
    #expect(sent.count == 1)
    if case let .syncStep2(update, _) = sent[0] {
        try remoteDoc.apply(update)
        let remoteText = try remoteDoc.text(named: "body")
        try remoteDoc.read { transaction in
            try #expect(transaction.string(from: remoteText) == "hello")
        }
    } else {
        Issue.record("Expected sync step 2 reply")
    }
}

@Test
func syncEngineAppliesStepTwoAndReportsSynced() throws {
    let sourceDoc = YDoc(clientID: 1)
    let sourceText = try sourceDoc.text(named: "body")
    try sourceDoc.write { transaction in
        try transaction.insert("synced", into: sourceText, at: 0)
    }

    let remoteDoc = YDoc(clientID: 2)
    let update = try sourceDoc.encodeStateAsUpdateV1(from: remoteDoc.stateVector())
    let engine = YSyncEngine(doc: remoteDoc, awareness: nil) { _ in }

    let result = try engine.handle(.syncStep2(update))

    #expect(result.didSync == true)
    let remoteText = try remoteDoc.text(named: "body")
    try remoteDoc.read { transaction in
        try #expect(transaction.string(from: remoteText) == "synced")
    }
}

@Test
func syncEngineHandlesAwarenessQueryAndTracksAppliedAwarenessStates() throws {
    let doc = YDoc(clientID: 1)
    let awareness = YAwareness(document: doc)
    try awareness.setLocalState(["name": "Ada"])
    var sent: [YSyncMessage] = []
    let engine = YSyncEngine(doc: doc, awareness: awareness) { message in
        sent.append(message)
    }

    _ = try engine.handle(.awarenessQuery())

    #expect(sent.count == 1)
    if case .awareness = sent[0] {} else {
        Issue.record("Expected awareness update")
    }

    let peerAwareness = YAwareness(document: YDoc(clientID: 2))
    try peerAwareness.setLocalState(["name": "Grace"])
    let peerUpdate = try peerAwareness.encodeUpdate()

    let result = try engine.handle(.awareness(peerUpdate))

    #expect(result.awarenessAddedClientIDs == [peerAwareness.clientID])
    #expect(result.awarenessRemovedClientIDs.isEmpty)
    let state = try #require(awareness.state(for: peerAwareness.clientID) as? [String: Any])
    #expect(state["name"] as? String == "Grace")
}

@Test
func syncEngineCanDiscardInboundDocumentUpdatesWhileHandlingAwareness() throws {
    let authorDoc = YDoc(clientID: 1)
    let authorText = try authorDoc.text(named: "body")
    let authorAwareness = YAwareness(document: authorDoc)
    let peerDoc = YDoc(clientID: 2)
    let peerText = try peerDoc.text(named: "body")
    try peerDoc.write { try $0.insert("peer", into: peerText, at: 0) }
    let peerUpdate = try peerDoc.encodeStateAsUpdateV1(from: authorDoc.stateVector())

    var sent: [YSyncMessage] = []
    let engine = YSyncEngine(
        doc: authorDoc,
        awareness: authorAwareness,
        send: { sent.append($0) },
        applyUpdate: { _ in },
        applyAwarenessUpdate: { try authorAwareness.applyUpdate($0) }
    )

    _ = try engine.handle(.syncStep1(peerDoc.stateVector()))
    #expect(sent.count == 1)
    if case .syncStep2 = sent[0] {} else {
        Issue.record("Expected sync step 2 reply")
    }

    _ = try engine.handle(.syncStep2(peerUpdate))
    _ = try engine.handle(.update(peerUpdate))
    for _ in 0..<10 {
        _ = try engine.handle(.update(peerUpdate))
    }
    try authorDoc.read { try #expect($0.string(from: authorText).isEmpty) }
    #expect(sent.count == 1)

    let peerAwareness = YAwareness(document: peerDoc)
    try peerAwareness.setLocalState(["name": "reader"])
    _ = try engine.handle(.awareness(peerAwareness.encodeUpdate()))
    let state = try #require(authorAwareness.state(for: peerAwareness.clientID) as? [String: Any])
    #expect(state["name"] as? String == "reader")
}
