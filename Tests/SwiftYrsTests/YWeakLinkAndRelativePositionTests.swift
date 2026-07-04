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

    var events: [YEvent] = []
    let observation = try link.observe { events.append($0) }
    defer {
        observation.cancel()
    }

    try doc.write { transaction in
        try transaction.set(.string("second"), forKey: "title", in: source)
    }

    #expect(events.count == 1)
    if case let .shared(shared) = events[0] {
        #expect(shared.target == .weak)
    } else {
        Issue.record("expected a shared weak event, got \(events[0])")
    }

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
func relativePositionsAnchorInsideXmlTextAndResolveToTheirNode() throws {
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    let (textNode, position) = try doc.write { transaction -> (YXmlText, YRelativePosition) in
        let paragraph = try transaction.insertElement(named: "paragraph", into: fragment, at: 0)
        let textNode = try transaction.insertText(into: paragraph, at: 0)
        try transaction.insert("hello", into: textNode, at: 0)
        let position = try transaction.relativePosition(in: textNode, at: 4, association: .after)
        return (textNode, position)
    }

    try doc.read { transaction in
        let resolved = try transaction.resolve(position)
        #expect(resolved.node == .xmlText(textNode))
        #expect(resolved.offset == 4)
    }
}

@Test
func xmlTextRelativePositionsStayAnchoredToTheirNodeAcrossEdits() throws {
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    let (secondText, position) = try doc.write { transaction -> (YXmlText, YRelativePosition) in
        let first = try transaction.insertElement(named: "paragraph", into: fragment, at: 0)
        let firstText = try transaction.insertText(into: first, at: 0)
        try transaction.insert("one", into: firstText, at: 0)
        let second = try transaction.insertElement(named: "paragraph", into: fragment, at: 1)
        let secondText = try transaction.insertText(into: second, at: 0)
        try transaction.insert("two", into: secondText, at: 0)
        return (secondText, try transaction.relativePosition(in: secondText, at: 1, association: .after))
    }

    try doc.write { transaction in
        try transaction.insert("YY", into: secondText, at: 0)
    }

    try doc.read { transaction in
        let resolved = try transaction.resolve(position)
        #expect(resolved.node == .xmlText(secondText))
        #expect(resolved.offset == 3)
    }
}

@Test
func webPeerRelativePositionJSONWithExplicitNullFieldsResolves() throws {
    // y-prosemirror awareness cursors serialize every RelativePosition field,
    // so absent scopes arrive as explicit nulls; they must decode and resolve.
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    let (textNode, position) = try doc.write { transaction -> (YXmlText, YRelativePosition) in
        let paragraph = try transaction.insertElement(named: "paragraph", into: fragment, at: 0)
        let textNode = try transaction.insertText(into: paragraph, at: 0)
        try transaction.insert("hello", into: textNode, at: 0)
        return (textNode, try transaction.relativePosition(in: textNode, at: 2, association: .after))
    }

    var json = try JSONSerialization.jsonObject(with: position.json) as? [String: Any] ?? [:]
    json["type"] = NSNull()
    json["tname"] = NSNull()
    let webShaped = try YRelativePosition(json: JSONSerialization.data(withJSONObject: json))

    try doc.read { transaction in
        let resolved = try transaction.resolve(webShaped)
        #expect(resolved.node == .xmlText(textNode))
        #expect(resolved.offset == 2)
    }
}

@Test
func typeScopedRelativePositionsWithRightAssociationResolveToTheTypeEnd() throws {
    // y-prosemirror encodes a cursor at the *end* of a textblock's text as a
    // relative position scoped to the text node itself: {type: <text node
    // id>, item: null, assoc: 0}. Yjs resolves that shape to the type's end
    // (`index = assoc >= 0 ? type._length : 0`); yrs's StickyIndex left the
    // nested-type scope at offset 0, so the bridge compensates — otherwise a
    // web peer's end-of-line cursor resolves to the line's start.
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    let (textNode, seed) = try doc.write { transaction -> (YXmlText, YRelativePosition) in
        let paragraph = try transaction.insertElement(named: "paragraph", into: fragment, at: 0)
        let textNode = try transaction.insertText(into: paragraph, at: 0)
        try transaction.insert("hello", into: textNode, at: 0)
        // An index-0 `.before` anchor is also scoped to the text node itself
        // ({type: …, assoc: -1}), so flipping assoc yields the web peer's
        // end-of-line shape deterministically.
        return (textNode, try transaction.relativePosition(in: textNode, at: 0, association: .before))
    }

    var json = try #require(JSONSerialization.jsonObject(with: seed.json) as? [String: Any])
    #expect(json["type"] != nil)
    #expect(json["item"] == nil)
    json["assoc"] = 0
    let endOfLine = try YRelativePosition(json: JSONSerialization.data(withJSONObject: json))

    try doc.read { transaction in
        let resolved = try transaction.resolve(endOfLine)
        #expect(resolved.node == .xmlText(textNode))
        #expect(resolved.offset == 5)

        // The left-associated twin keeps Yjs's other branch: assoc < 0 → offset 0.
        let leftAssociated = try transaction.resolve(seed)
        #expect(leftAssociated.node == .xmlText(textNode))
        #expect(leftAssociated.offset == 0)
    }
}

@Test
func elementScopedRelativePositionsWithRightAssociationResolveAfterTheLastChild() throws {
    // The same Yjs rule for elements: {type: <element id>, item: null,
    // assoc: 0} resolves to the element's child count, not its first child.
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    let (paragraph, position) = try doc.write { transaction -> (YXmlElement, YRelativePosition) in
        let paragraph = try transaction.insertElement(named: "blockquote", into: fragment, at: 0)
        _ = try transaction.insertElement(named: "paragraph", into: paragraph, at: 0)
        _ = try transaction.insertElement(named: "paragraph", into: paragraph, at: 1)
        return (paragraph, try transaction.relativePosition(anchoredTo: paragraph, association: .after))
    }

    try doc.read { transaction in
        let resolved = try transaction.resolve(position)
        #expect(resolved.node == .xmlElement(paragraph))
        #expect(resolved.offset == 2)
    }
}

@Test
func rootScopedRelativePositionsResolveToTheFragmentEnd() throws {
    // y-prosemirror anchors a document-end cursor to the root type by name
    // (`tname`), not to an item.
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    try doc.write { transaction in
        let paragraph = try transaction.insertElement(named: "paragraph", into: fragment, at: 0)
        let textNode = try transaction.insertText(into: paragraph, at: 0)
        try transaction.insert("hello", into: textNode, at: 0)
    }

    let json = try JSONSerialization.data(withJSONObject: [
        "type": NSNull(), "tname": "prosemirror", "item": NSNull(), "assoc": 0,
    ])
    let position = try YRelativePosition(json: json)

    try doc.read { transaction in
        let resolved = try transaction.resolve(position)
        #expect(resolved.node == .xmlFragment(fragment))
        let childCount = try transaction.childCount(of: fragment)
        #expect(resolved.offset == childCount)
    }
}

@Test
func elementAnchoredRelativePositionsResolveToTheElement() throws {
    // A caret in an empty paragraph has no text node to anchor into;
    // y-prosemirror anchors it to the paragraph element itself.
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    let (paragraph, position) = try doc.write { transaction -> (YXmlElement, YRelativePosition) in
        let paragraph = try transaction.insertElement(named: "paragraph", into: fragment, at: 0)
        return (paragraph, try transaction.relativePosition(anchoredTo: paragraph, association: .after))
    }

    try doc.write { transaction in
        _ = try transaction.insertElement(named: "heading", into: fragment, at: 0)
    }

    try doc.read { transaction in
        let resolved = try transaction.resolve(position)
        #expect(resolved.node == .xmlElement(paragraph))
        #expect(resolved.offset == 0)
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
