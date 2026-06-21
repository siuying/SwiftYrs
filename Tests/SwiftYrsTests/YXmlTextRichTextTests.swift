import Foundation
import Testing
import SwiftYrs

private func makeXmlText(in fragment: YXmlFragment, transaction: YWriteTransaction) throws -> YXmlText {
    let paragraph = try transaction.insertElement(named: "paragraph", into: fragment, at: 0)
    return try transaction.insertText(into: paragraph, at: 0)
}

/// Decodes a `deltaJSON` payload into a comparable `[(insert, attributes)]` form.
private func decodeDelta(_ data: Data) throws -> [(insert: String, attributes: NSDictionary)] {
    let ops = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    return ops.map { op in
        (
            insert: op["insert"] as? String ?? "",
            attributes: (op["attributes"] as? NSDictionary) ?? NSDictionary()
        )
    }
}

@Test
func xmlTextInsertWithAttributesPreservesObjectValuedMarks() throws {
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    try doc.write { transaction in
        let text = try makeXmlText(in: fragment, transaction: transaction)
        // y-prosemirror encodes every mark as an object value, even when empty.
        try transaction.insert(
            "bold",
            into: text,
            at: 0,
            attributesJSON: Data(#"{"bold":{}}"#.utf8)
        )
        try transaction.insert(
            "link",
            into: text,
            at: 4,
            attributesJSON: Data(#"{"link":{"href":"https://example.com"}}"#.utf8)
        )

        let delta = try decodeDelta(transaction.deltaJSON(from: text))
        #expect(delta.count == 2)
        #expect(delta[0].insert == "bold")
        #expect(delta[0].attributes == ["bold": [:]] as NSDictionary)
        #expect(delta[1].insert == "link")
        #expect(delta[1].attributes == ["link": ["href": "https://example.com"]] as NSDictionary)
    }
}

@Test
func xmlTextFormatAppliesObjectMarkToExistingRange() throws {
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    try doc.write { transaction in
        let text = try makeXmlText(in: fragment, transaction: transaction)
        try transaction.insert("hello world", into: text, at: 0)
        try transaction.format(text, at: 6, length: 5, attributesJSON: Data(#"{"italic":{}}"#.utf8))

        let delta = try decodeDelta(transaction.deltaJSON(from: text))
        #expect(delta.map(\.insert) == ["hello ", "world"])
        #expect(delta[0].attributes == [:] as NSDictionary)
        #expect(delta[1].attributes == ["italic": [:]] as NSDictionary)
    }
}

@Test
func xmlTextApplyDeltaJSONHandlesRetainDeleteInsert() throws {
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    try doc.write { transaction in
        let text = try makeXmlText(in: fragment, transaction: transaction)
        try transaction.insert("hello world", into: text, at: 0)
        try transaction.applyDeltaJSON(
            Data(#"[{"retain":6},{"delete":5},{"insert":"Swift","attributes":{"code":{}}}]"#.utf8),
            to: text
        )

        // `string(from:)` renders formatted runs as inline XML tags
        // (`hello <code>Swift</code>`), so formatted content must be read back
        // via the delta — the concatenated insert text is the plain string.
        let delta = try decodeDelta(transaction.deltaJSON(from: text))
        #expect(delta.map(\.insert).joined() == "hello Swift")
        #expect(delta.map(\.insert) == ["hello ", "Swift"])
        #expect(delta[0].attributes == [:] as NSDictionary)
        #expect(delta.last?.attributes == ["code": [:]] as NSDictionary)
    }
}

@Test
func xmlTextRichFormattingRoundtripsThroughDocumentUpdates() throws {
    let source = YDoc()
    let destination = YDoc()
    let sourceFragment = try source.xmlFragment(named: "prosemirror")
    let destinationFragment = try destination.xmlFragment(named: "prosemirror")

    try source.write { transaction in
        let text = try makeXmlText(in: sourceFragment, transaction: transaction)
        try transaction.insert("hello", into: text, at: 0, attributesJSON: Data(#"{"bold":{}}"#.utf8))
        try transaction.insert(" world", into: text, at: 5, attributesJSON: Data("{}".utf8))
    }

    try destination.apply(try source.encodeStateAsUpdateV1())

    try destination.read { transaction in
        guard case let .element(paragraph) = try transaction.child(at: 0, in: destinationFragment),
              case let .text(text) = try transaction.child(at: 0, in: paragraph)
        else {
            Issue.record("expected paragraph > text in replicated fragment")
            return
        }
        let delta = try decodeDelta(transaction.deltaJSON(from: text))
        #expect(delta.map(\.insert) == ["hello", " world"])
        #expect(delta[0].attributes == ["bold": [:]] as NSDictionary)
        #expect(delta[1].attributes == [:] as NSDictionary)
    }
}
