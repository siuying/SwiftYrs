import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import Testing

@Test
func clientDiffCaptureReturnsTargetClientUpdateAndCurrentClock() throws {
    let capture = ClientDiffCapture()
    let doc = try mergedDocument()

    #expect(try capture.currentClock(in: doc, clientID: 1) == 3)
    #expect(try capture.currentClock(in: doc, clientID: 2) == 3)

    let update = try #require(try capture.clientDiff(in: doc, clientID: 1, fromClock: 0))
    let destination = YDoc()
    let destinationText = try destination.text(named: "body")
    try destination.apply(update)

    try destination.read { transaction in
        try #expect(transaction.string(from: destinationText) == "one")
    }
}

@Test
func clientDiffCaptureReturnsNilWhenClientClockHasNotAdvanced() throws {
    let capture = ClientDiffCapture()
    let doc = try mergedDocument()
    let currentClock = try capture.currentClock(in: doc, clientID: 1)

    #expect(try capture.clientDiff(in: doc, clientID: 1, fromClock: currentClock) == nil)
    #expect(try capture.clientDiff(in: doc, clientID: 99, fromClock: 0) == nil)
}

@Test
func clientDiffCaptureMatchesYjsFixtureBytes() throws {
    let fixture = try ClientScopedDiffFixture.load()
    let capture = ClientDiffCapture()
    let doc = YDoc()
    try doc.apply(.v1(fixture.clientOneUpdate))
    try doc.apply(.v1(fixture.clientTwoUpdate))

    #expect(try capture.currentClock(in: doc, clientID: fixture.clientID) == fixture.expectedClock)
    #expect(
        try capture.clientDiff(
            in: doc,
            clientID: fixture.clientID,
            fromClock: fixture.fromClock
        )?.data == fixture.clientOneDiff
    )
}

private func mergedDocument() throws -> YDoc {
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
    return merged
}

private struct ClientScopedDiffFixture: Decodable {
    let clientID: UInt64
    let fromClock: UInt32
    let expectedClock: UInt32
    let clientOneUpdate: Data
    let clientTwoUpdate: Data
    let clientOneDiff: Data

    private enum CodingKeys: String, CodingKey {
        case clientID
        case fromClock
        case expectedClock
        case clientOneUpdate
        case clientTwoUpdate
        case clientOneDiff
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try container.decode(UInt64.self, forKey: .clientID)
        fromClock = try container.decode(UInt32.self, forKey: .fromClock)
        expectedClock = try container.decode(UInt32.self, forKey: .expectedClock)
        clientOneUpdate = try Self.decodeBase64(.clientOneUpdate, from: container)
        clientTwoUpdate = try Self.decodeBase64(.clientTwoUpdate, from: container)
        clientOneDiff = try Self.decodeBase64(.clientOneDiff, from: container)
    }

    static func load() throws -> ClientScopedDiffFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "client-scoped-diff",
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(forResource: "client-scoped-diff", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClientScopedDiffFixture.self, from: data)
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
