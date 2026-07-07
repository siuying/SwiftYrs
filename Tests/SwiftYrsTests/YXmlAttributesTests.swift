import Foundation
import Testing
import SwiftYrs

@Test
func xmlElementAttributesEnumerateAllKeys() throws {
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    try doc.write { transaction in
        let heading = try transaction.insertElement(named: "heading", into: fragment, at: 0)
        try transaction.setAttribute(.int(2), forKey: "level", in: heading)
        try transaction.setAttribute(.string("center"), forKey: "textAlign", in: heading)

        let object = try JSONSerialization.jsonObject(
            with: transaction.attributesJSON(from: heading)
        ) as? [String: Any]
        #expect((object?["level"] as? NSNumber)?.intValue == 2)
        #expect(object?["textAlign"] as? String == "center")
        #expect(object?.count == 2)
    }
}

@Test
func xmlElementAttributesRoundtripThroughUpdate() throws {
    let source = YDoc()
    let destination = YDoc()
    let sourceFragment = try source.xmlFragment(named: "prosemirror")
    let destinationFragment = try destination.xmlFragment(named: "prosemirror")

    try source.write { transaction in
        let element = try transaction.insertElement(named: "orderedList", into: sourceFragment, at: 0)
        try transaction.setAttribute(.int(3), forKey: "start", in: element)
    }

    try destination.apply(try source.encodeStateAsUpdateV1())

    try destination.read { transaction in
        guard case let .element(element) = try transaction.child(at: 0, in: destinationFragment) else {
            Issue.record("expected element child")
            return
        }
        let object = try JSONSerialization.jsonObject(
            with: transaction.attributesJSON(from: element)
        ) as? [String: Any]
        #expect((object?["start"] as? NSNumber)?.intValue == 3)
    }
}

@Test
func xmlElementArrayAttributeRoundtripsThroughAttributesJSON() throws {
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    try doc.write { transaction in
        let cell = try transaction.insertElement(named: "tableCell", into: fragment, at: 0)
        let colwidth = try JSONSerialization.data(withJSONObject: [100, 200])
        try transaction.setAttribute(json: colwidth, forKey: "colwidth", in: cell)

        let object = try JSONSerialization.jsonObject(
            with: transaction.attributesJSON(from: cell)
        ) as? [String: Any]
        let widths = (object?["colwidth"] as? [NSNumber])?.map(\.intValue)
        #expect(widths == [100, 200])
    }
}

@Test
func xmlElementObjectAttributeRoundtripsThroughAttributesJSON() throws {
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    try doc.write { transaction in
        let cell = try transaction.insertElement(named: "tableCell", into: fragment, at: 0)
        let meta = try JSONSerialization.data(withJSONObject: ["rowspan": 2, "header": false])
        try transaction.setAttribute(json: meta, forKey: "meta", in: cell)

        let object = try JSONSerialization.jsonObject(
            with: transaction.attributesJSON(from: cell)
        ) as? [String: Any]
        let decoded = object?["meta"] as? [String: Any]
        #expect((decoded?["rowspan"] as? NSNumber)?.intValue == 2)
        #expect((decoded?["header"] as? NSNumber)?.boolValue == false)
    }
}

@Test
func xmlElementAnyAttributeSurvivesUpdateSync() throws {
    let source = YDoc()
    let destination = YDoc()
    let sourceFragment = try source.xmlFragment(named: "prosemirror")
    let destinationFragment = try destination.xmlFragment(named: "prosemirror")

    try source.write { transaction in
        let cell = try transaction.insertElement(named: "tableCell", into: sourceFragment, at: 0)
        let colwidth = try JSONSerialization.data(withJSONObject: [120, 240, 360])
        try transaction.setAttribute(json: colwidth, forKey: "colwidth", in: cell)
    }

    try destination.apply(try source.encodeStateAsUpdateV1())

    try destination.read { transaction in
        guard case let .element(cell) = try transaction.child(at: 0, in: destinationFragment) else {
            Issue.record("expected element child")
            return
        }
        let object = try JSONSerialization.jsonObject(
            with: transaction.attributesJSON(from: cell)
        ) as? [String: Any]
        let widths = (object?["colwidth"] as? [NSNumber])?.map(\.intValue)
        #expect(widths == [120, 240, 360])
    }
}

@Test
func xmlElementDecodesJavaScriptArrayAndObjectAttribute() throws {
    // A y-prosemirror-style peer wrote `colwidth` as an array and `meta` as an
    // object (each a single ContentAny). A Swift peer must decode them as a
    // plain array/object — parity for SwiftYrs#105 / ProseKit#118.
    let fixture = try YjsFixture.load("xml-any-attribute-document")
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    try doc.apply(.v1(fixture.updateV1))

    try doc.read { transaction in
        guard case let .element(cell) = try transaction.child(at: 0, in: fragment) else {
            Issue.record("expected element child")
            return
        }
        let object = try JSONSerialization.jsonObject(
            with: transaction.attributesJSON(from: cell)
        ) as? [String: Any]
        let widths = (object?["colwidth"] as? [NSNumber])?.map(\.intValue)
        #expect(widths == [100, 200])
        let meta = object?["meta"] as? [String: Any]
        #expect((meta?["rowspan"] as? NSNumber)?.intValue == 2)
        #expect((meta?["header"] as? NSNumber)?.boolValue == false)
        #expect(object?["scalar"] as? String == "kept")
    }
}

@Test
func xmlElementWithNoAttributesIsEmptyObject() throws {
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "prosemirror")

    try doc.write { transaction in
        let paragraph = try transaction.insertElement(named: "paragraph", into: fragment, at: 0)
        let object = try JSONSerialization.jsonObject(
            with: transaction.attributesJSON(from: paragraph)
        ) as? [String: Any]
        #expect(object?.isEmpty == true)
    }
}
