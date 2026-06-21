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
