import Foundation
import Testing
import SwiftYrs

@Test
func xmlFragmentSupportsTreeEditsAttributesAndStringSerialization() throws {
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "article")

    try doc.write { transaction in
        let paragraph = try transaction.insertElement(named: "p", into: fragment, at: 0)
        try transaction.setAttribute(.string("lead"), forKey: "class", in: paragraph)
        let text = try transaction.insertText(into: paragraph, at: 0)
        try transaction.insert("Hello XML", into: text, at: 0)

        try #expect(transaction.childCount(of: fragment) == 1)
        try #expect(transaction.tag(of: paragraph) == "p")
        try #expect(transaction.getAttribute("class", from: paragraph) == .string("lead"))
        try #expect(transaction.string(from: text) == "Hello XML")
        try #expect(transaction.string(from: fragment) == "<p class=\"lead\">Hello XML</p>")

        guard case let .element(child) = try transaction.child(at: 0, in: fragment) else {
            Issue.record("Expected XML element child")
            return
        }
        try #expect(transaction.tag(of: child) == "p")

        try transaction.removeAttribute("class", from: paragraph)
        try #expect(transaction.getAttribute("class", from: paragraph) == .undefined)
    }
}

@Test
func xmlTextSupportsTextRemovalAndAttributes() throws {
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "article")

    try doc.write { transaction in
        let text = try transaction.insertText(into: fragment, at: 0)
        try transaction.insert("abcdef", into: text, at: 0)
        try transaction.remove(from: text, at: 2, length: 2)
        try transaction.setAttribute(.string("plain"), forKey: "kind", in: text)

        try #expect(transaction.length(of: text) == 4)
        try #expect(transaction.string(from: text) == "abef")
        try #expect(transaction.getAttribute("kind", from: text) == .string("plain"))
        try #expect(transaction.string(from: fragment) == "abef")
    }
}

@Test
func xmlContentRoundtripsThroughDocumentUpdates() throws {
    let source = YDoc()
    let destination = YDoc()
    let sourceFragment = try source.xmlFragment(named: "article")
    let destinationFragment = try destination.xmlFragment(named: "article")

    try source.write { transaction in
        let paragraph = try transaction.insertElement(named: "p", into: sourceFragment, at: 0)
        let text = try transaction.insertText(into: paragraph, at: 0)
        try transaction.insert("Synced", into: text, at: 0)
    }

    try destination.apply(try source.encodeStateAsUpdateV1())

    try destination.read { transaction in
        try #expect(transaction.string(from: destinationFragment) == "<p>Synced</p>")
    }
}

@Test
func xmlCanApplyJavaScriptYjsFixture() throws {
    let fixture = try YjsFixture.load("xml-document")
    let doc = YDoc()
    let fragment = try doc.xmlFragment(named: "article")

    try doc.apply(.v1(fixture.updateV1))

    try doc.read { transaction in
        try #expect(transaction.string(from: fragment) == "<p class=\"lead\">Hello XML</p>")
        guard case let .element(paragraph) = try transaction.child(at: 0, in: fragment) else {
            Issue.record("Expected XML element child")
            return
        }
        try #expect(transaction.getAttribute("class", from: paragraph) == .string("lead"))
    }
}

@Test
func subdocsCanBeInsertedLoadedListedAndClearedFromMaps() throws {
    let doc = YDoc()
    let map = try doc.map(named: "subdocs")

    let created = try doc.write { transaction in
        let subdoc = try transaction.setNewSubdoc(forKey: "child", in: map)
        try transaction.loadSubdoc(forKey: "child", in: map)
        return subdoc
    }

    try doc.read { transaction in
        try #expect(transaction.subdoc(forKey: "child", in: map) == created)
        try #expect(transaction.subdocGuids().contains(created.guid))
    }

    try doc.write { transaction in
        try transaction.clearSubdoc(forKey: "child", in: map)
        try #expect(transaction.subdocGuids().contains(created.guid))
    }
}
