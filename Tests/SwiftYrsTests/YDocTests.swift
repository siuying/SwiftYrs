import Foundation
import Testing
import SwiftYrs

@Test
func documentCanRoundtripThroughYrsBridge() {
    _ = YDoc()
}

@Test
func documentExposesClientID() {
    let doc = YDoc(clientID: 42)

    #expect(doc.clientID == 42)
}

@Test
func documentProvidesClosureScopedTransactions() throws {
    let doc = YDoc()

    try doc.read { transaction in
        try #expect(transaction.isWritable == false)
    }

    try doc.write { transaction in
        try #expect(transaction.isWritable == true)
    }
}

@Test
func nestedTransactionsThrowConflictError() throws {
    let doc = YDoc()

    _ = try doc.write { _ in
        #expect(throws: YError.transactionConflict) {
            try doc.read { _ in }
        }
    }
}

@Test
func stateVectorAndUpdatesMatchYjsEmptyDocumentFixture() throws {
    let fixture = try YjsFixture.load("empty-document")
    let doc = YDoc()

    try #expect(doc.stateVector().data == fixture.stateVector)
    try #expect(doc.encodeStateAsUpdateV1().data == fixture.updateV1)
    try #expect(doc.encodeStateAsUpdateV2().data == fixture.updateV2)
}

@Test
func stateVectorCanGenerateNoopDiffsForAnotherDocument() throws {
    let source = YDoc()
    let destination = YDoc()
    let destinationState = try destination.stateVector()

    let updateV1 = try source.encodeStateAsUpdateV1(from: destinationState)
    try destination.apply(updateV1)
    let stateAfterV1 = try destination.stateVector()
    let sourceState = try source.stateVector()
    #expect(stateAfterV1 == sourceState)

    let updateV2 = try source.encodeStateAsUpdateV2(from: destinationState)
    try destination.apply(updateV2)
    let stateAfterV2 = try destination.stateVector()
    #expect(stateAfterV2 == sourceState)
}

@Test
func clientDiffIncludesOnlyTheRequestedClientInsertionsSinceClock() throws {
    let clientOne = YDoc(clientID: 1)
    let clientOneText = try clientOne.text(named: "body")
    try clientOne.write { transaction in
        try transaction.insert("one", into: clientOneText, at: 0)
    }

    let clientTwo = YDoc(clientID: 2)
    let clientTwoText = try clientTwo.text(named: "body")
    try clientTwo.write { transaction in
        try transaction.insert("two", into: clientTwoText, at: 0)
    }

    let merged = YDoc()
    try merged.apply(try clientOne.encodeStateAsUpdateV1())
    try merged.apply(try clientTwo.encodeStateAsUpdateV1())

    let clientOneDiff = try merged.encodeClientStateAsUpdateV1(clientID: 1, fromClock: 0)

    let destination = YDoc()
    let destinationText = try destination.text(named: "body")
    try destination.apply(clientOneDiff)

    try destination.read { transaction in
        try #expect(transaction.string(from: destinationText) == "one")
    }
}

@Test
func clientDiffStartsAtTheRequestedClientClock() throws {
    let doc = YDoc(clientID: 7)
    let text = try doc.text(named: "body")

    try doc.write { transaction in
        try transaction.insert("old", into: text, at: 0)
    }
    let marker = try doc.clientClock(clientID: 7)
    let initialUpdate = try doc.encodeStateAsUpdateV1()

    try doc.write { transaction in
        try transaction.insert("new", into: text, at: 3)
    }

    let diff = try doc.encodeClientStateAsUpdateV1(clientID: 7, fromClock: marker)
    let destination = YDoc()
    let destinationText = try destination.text(named: "body")
    try destination.apply(initialUpdate)
    try destination.apply(diff)

    try destination.read { transaction in
        try #expect(transaction.string(from: destinationText) == "oldnew")
    }
}

@Test
func invalidUpdatesThrowDecodeFailure() throws {
    let doc = YDoc()

    #expect(throws: YError.decodeFailure) {
        try doc.apply(.v1(Data([0xff])))
    }
}

struct YjsFixture: Decodable {
    let stateVector: Data
    let updateV1: Data
    let updateV2: Data

    private enum CodingKeys: String, CodingKey {
        case stateVector
        case updateV1
        case updateV2
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stateVector = try Self.decodeBase64(.stateVector, from: container)
        updateV1 = try Self.decodeBase64(.updateV1, from: container)
        updateV2 = try Self.decodeBase64(.updateV2, from: container)
    }

    static func load(_ name: String) throws -> YjsFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(forResource: name, withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(YjsFixture.self, from: data)
    }

    private static func decodeBase64(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Data {
        let value = try container.decode(String.self, forKey: key)
        guard let data = Data(base64Encoded: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected base64-encoded bytes"
            )
        }
        return data
    }
}
