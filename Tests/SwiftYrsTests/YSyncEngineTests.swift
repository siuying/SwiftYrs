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
