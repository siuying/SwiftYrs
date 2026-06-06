import Foundation
import Testing
import SwiftYrs

@Test
func mapWeakLinksDereferenceUpdatedAndDeletedEntries() throws {
    let doc = YDoc()
    let source = try doc.map(named: "source")
    let links = try doc.map(named: "links")

    let link = try doc.write { transaction in
        try transaction.set(.string("first"), forKey: "title", in: source)
        return try transaction.setWeakLink(toKey: "title", in: source, forKey: "title-link", in: links)
    }

    try doc.read { transaction in
        try #expect(transaction.dereference(link) == .string("first"))
        try #expect(transaction.weakLink(forKey: "title-link", in: links) == link)
    }

    var events: [YObservationEvent] = []
    let observation = try link.observe { events.append($0) }
    defer {
        observation.cancel()
    }

    try doc.write { transaction in
        try transaction.set(.string("second"), forKey: "title", in: source)
    }

    #expect(events.count == 1)
    #expect(events[0].kind == "weak")

    try doc.write { transaction in
        try #expect(transaction.dereference(link) == .string("second"))
        try transaction.remove("title", from: source)
        try #expect(transaction.dereference(link) == .undefined)
    }
}

@Test
func textQuotationWeakLinksTrackBoundaryEdits() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    let links = try doc.map(named: "links")

    let exclusive = try doc.write { transaction in
        try transaction.insert("hello!", into: text, at: 0)
        return try transaction.setTextQuote(
            text,
            start: 0,
            end: 5,
            endInclusive: false,
            forKey: "quote",
            in: links
        )
    }

    try doc.write { transaction in
        try #expect(transaction.string(from: exclusive) == "hello")
        try transaction.insert(" world", into: text, at: 5)
        try #expect(transaction.string(from: exclusive) == "hello world")
    }
}

@Test
func arrayQuotationWeakLinksUnquoteInsertedValuesWithinRange() throws {
    let doc = YDoc()
    let array = try doc.array(named: "items")
    let links = try doc.map(named: "links")

    let quote = try doc.write { transaction in
        try transaction.insert(.string("A"), into: array, at: 0)
        try transaction.insert(.string("B"), into: array, at: 1)
        try transaction.insert(.string("C"), into: array, at: 2)
        try transaction.insert(.string("D"), into: array, at: 3)
        return try transaction.setArrayQuote(array, start: 1, end: 2, endInclusive: true, forKey: "quote", in: links)
    }

    try doc.write { transaction in
        try #expect(transaction.values(from: quote) == [.string("B"), .string("C")])
        try transaction.insert(.string("X"), into: array, at: 2)
        try #expect(transaction.values(from: quote) == [.string("B"), .string("X"), .string("C")])
    }
}

@Test
func relativePositionsStayStableAcrossTextEditsAndRoundtripEncoding() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")

    let position = try doc.write { transaction in
        try transaction.insert("hello", into: text, at: 0)
        return try transaction.relativePosition(in: text, at: 4, association: .after)
    }

    try doc.write { transaction in
        try #expect(transaction.offset(of: position, in: text) == 4)
        try transaction.insert("YY", into: text, at: 1)
        try #expect(transaction.offset(of: position, in: text) == 6)

        let fromData = try YRelativePosition(data: position.data)
        let fromJSON = try YRelativePosition(json: position.json)
        try #expect(transaction.offset(of: fromData, in: text) == 6)
        try #expect(transaction.offset(of: fromJSON, in: text) == 6)
    }
}

@Test
func relativePositionsDecodeJavaScriptYjsFixture() throws {
    let fixture = try YjsRelativePositionFixture.load("relative-position-document")
    let doc = YDoc()
    let text = try doc.text(named: "body")

    try doc.apply(.v1(fixture.updateV1))

    let fromData = try YRelativePosition(data: fixture.relativePositionV1)
    let fromJSON = try YRelativePosition(json: fixture.relativePositionJSON)

    try doc.read { transaction in
        try #expect(transaction.string(from: text) == "hello")
        try #expect(transaction.offset(of: fromData, in: text) == 4)
        try #expect(transaction.offset(of: fromJSON, in: text) == 4)
    }
}

private struct YjsRelativePositionFixture: Decodable {
    let updateV1: Data
    let relativePositionV1: Data
    let relativePositionJSON: Data

    private enum CodingKeys: String, CodingKey {
        case updateV1
        case relativePositionV1
        case relativePositionJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updateV1 = try Self.decodeBase64(.updateV1, from: container)
        relativePositionV1 = try Self.decodeBase64(.relativePositionV1, from: container)
        let jsonObject = try container.decode([String: RelativePositionJSONValue].self, forKey: .relativePositionJSON)
        relativePositionJSON = try JSONEncoder().encode(jsonObject)
    }

    static func load(_ name: String) throws -> YjsRelativePositionFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(forResource: name, withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(YjsRelativePositionFixture.self, from: data)
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

private enum RelativePositionJSONValue: Codable {
    case int(Int64)
    case string(String)
    case object([String: RelativePositionJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .object(try container.decode([String: RelativePositionJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .int(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}
