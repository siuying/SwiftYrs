import Foundation
import Testing
import SwiftYrs

private struct YjsSyncFixture: Decodable {
    let multiMessage: Data

    private enum CodingKeys: String, CodingKey {
        case multiMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .multiMessage)
        guard let data = Data(base64Encoded: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .multiMessage,
                in: container,
                debugDescription: "Expected base64-encoded bytes"
            )
        }
        multiMessage = data
    }

    static func load(_ name: String) throws -> YjsSyncFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(forResource: name, withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(YjsSyncFixture.self, from: data)
    }
}

@Test
func syncMessagesEncodeAndDecodeTypedPayloads() throws {
    let doc = YDoc(clientID: 1)
    let stateVector = try doc.stateVector()
    let update = try doc.encodeStateAsUpdateV1()
    let awareness = YAwareness(document: doc)
    try awareness.setLocalState(["name": "Ada"])
    let awarenessUpdate = try awareness.encodeUpdate()

    let messages: [YSyncMessage] = [
        try .syncStep1(stateVector),
        try .syncStep2(update),
        try .update(update),
        try .awareness(awarenessUpdate),
        try .awarenessQuery()
    ]

    let decoded = try YSyncMessage.decodePayload(YSyncMessage.joinedPayload(messages))

    #expect(decoded.count == 5)
    if case let .syncStep1(decodedStateVector, _) = decoded[0] {
        #expect(decodedStateVector == stateVector)
    } else {
        Issue.record("Expected sync step 1")
    }
    if case let .syncStep2(decodedUpdate, _) = decoded[1] {
        #expect(decodedUpdate == update)
    } else {
        Issue.record("Expected sync step 2")
    }
    if case let .update(decodedUpdate, _) = decoded[2] {
        #expect(decodedUpdate == update)
    } else {
        Issue.record("Expected update")
    }
    if case let .awareness(decodedAwareness, _) = decoded[3] {
        #expect(decodedAwareness == awarenessUpdate)
    } else {
        Issue.record("Expected awareness")
    }
    if case .awarenessQuery = decoded[4] {} else {
        Issue.record("Expected awareness query")
    }
}

@Test
func syncProtocolAppliesStepOneResponseToRemoteDocument() throws {
    let sourceDoc = YDoc(clientID: 1)
    let sourceText = try sourceDoc.text(named: "body")
    try sourceDoc.write { transaction in
        try transaction.insert("hello", into: sourceText, at: 0)
    }
    let sourceAwareness = YAwareness(document: sourceDoc)

    let remoteDoc = YDoc(clientID: 2)
    let remoteText = try remoteDoc.text(named: "body")
    let remoteAwareness = YAwareness(document: remoteDoc)
    let request = try YSyncMessage.syncStep1(remoteDoc.stateVector())

    let response = try YSyncProtocol.handle(request.payload, awareness: sourceAwareness)
    let responseMessages = try YSyncMessage.decodePayload(response)
    #expect(responseMessages.count == 1)
    if case .syncStep2 = responseMessages[0] {} else {
        Issue.record("Expected sync step 2 response")
    }

    let reply = try YSyncProtocol.handle(response, awareness: remoteAwareness)
    #expect(reply.isEmpty)
    try remoteDoc.read { transaction in
        try #expect(transaction.string(from: remoteText) == "hello")
    }
}

@Test
func syncProtocolStartReturnsStepOneAndAwarenessMessages() throws {
    let awareness = YAwareness(document: YDoc(clientID: 1))
    try awareness.setLocalState(["name": "Ada"])

    let payload = try YSyncProtocol.start(awareness: awareness)
    let messages = try YSyncMessage.decodePayload(payload)

    #expect(messages.count == 2)
    if case .syncStep1 = messages[0] {} else {
        Issue.record("Expected sync step 1")
    }
    if case .awareness = messages[1] {} else {
        Issue.record("Expected awareness")
    }
}

@Test
func syncDecodeRejectsMalformedPayloads() throws {
    #expect(throws: YError.decodeFailure) {
        try YSyncMessage.decodePayload(Data([0xff, 0xff]))
    }
}

@Test
func syncCanDecodeJavaScriptYjsFixture() throws {
    let fixture = try YjsSyncFixture.load("sync-messages")
    let decoded = try YSyncMessage.decodePayload(fixture.multiMessage)

    #expect(decoded.count == 4)
    if case .syncStep1 = decoded[0] {} else {
        Issue.record("Expected JS sync step 1")
    }
    if case let .update(update, _) = decoded[1] {
        let doc = YDoc(clientID: 22)
        let text = try doc.text(named: "body")
        try doc.write { transaction in
            try transaction.apply(update)
        }
        try doc.read { transaction in
            try #expect(transaction.string(from: text) == "from js")
        }
    } else {
        Issue.record("Expected JS update")
    }
    if case let .awareness(update, _) = decoded[2] {
        let awareness = YAwareness(document: YDoc(clientID: 22))
        try awareness.applyUpdate(update)
        let state = try #require(awareness.state(for: 21) as? [String: Any])
        #expect(state["name"] as? String == "sync-js")
    } else {
        Issue.record("Expected JS awareness")
    }
    if case .awarenessQuery = decoded[3] {} else {
        Issue.record("Expected JS awareness query")
    }
}
