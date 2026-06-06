import Foundation
import Testing
import SwiftYrs

@Test
func textChunksExposeFormattingAttributes() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")

    try doc.write { transaction in
        try transaction.insert("hello", into: text, at: 0, attributes: ["bold": .bool(true)])
        try transaction.insert(" world", into: text, at: 5)

        let chunks = try transaction.chunks(from: text)
        #expect(chunks == [
            YTextChunk(insert: .string("hello world"), attributes: ["bold": .bool(true)])
        ])
    }
}

@Test
func textCanFormatExistingRangesAndExposeOutputDelta() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")

    try doc.write { transaction in
        try transaction.insert("hello world", into: text, at: 0)
        try transaction.format(text, at: 6, length: 5, attributes: ["italic": .bool(true)])

        try #expect(transaction.delta(from: text) == [
            .insert(.string("hello "), attributes: [:]),
            .insert(.string("world"), attributes: ["italic": .bool(true)])
        ])
    }
}

@Test
func textCanApplyRetainDeleteInsertDeltaOperations() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")

    try doc.write { transaction in
        try transaction.insert("hello world", into: text, at: 0)
        try transaction.applyDelta([
            .retain(6),
            .delete(5),
            .insert(.string("Swift"), attributes: ["code": .bool(true)])
        ], to: text)

        try #expect(transaction.string(from: text) == "hello Swift")
        try #expect(transaction.chunks(from: text).last == YTextChunk(
            insert: .string("Swift"),
            attributes: ["code": .bool(true)]
        ))
    }
}

@Test
func textChunksPreserveBinaryEmbeds() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    let image = Data([0xde, 0xad, 0xbe, 0xef])

    try doc.write { transaction in
        try transaction.insert("a", into: text, at: 0)
        try transaction.insertEmbed(.binary(image), into: text, at: 1, attributes: ["width": .int(320)])
        try transaction.insert("b", into: text, at: 2)

        #expect(try transaction.string(from: text) == "ab")
        try #expect(transaction.chunks(from: text) == [
            YTextChunk(insert: .string("a"), attributes: [:]),
            YTextChunk(insert: .binary(image), attributes: ["width": .int(320)]),
            YTextChunk(insert: .string("b"), attributes: ["width": .int(320)])
        ])
    }
}

@Test
func richTextRoundtripsThroughDocumentUpdates() throws {
    let source = YDoc()
    let destination = YDoc()
    let sourceText = try source.text(named: "body")
    let destinationText = try destination.text(named: "body")

    try source.write { transaction in
        try transaction.insert("hello", into: sourceText, at: 0, attributes: ["bold": .bool(true)])
        try transaction.insertEmbed(.binary(Data([1, 2, 3])), into: sourceText, at: 5)
    }

    try destination.apply(try source.encodeStateAsUpdateV1())

    try destination.read { transaction in
        try #expect(transaction.chunks(from: destinationText) == [
            YTextChunk(insert: .string("hello"), attributes: ["bold": .bool(true)]),
            YTextChunk(insert: .binary(Data([1, 2, 3])), attributes: [:])
        ])
    }
}

@Test
func richTextCanApplyJavaScriptYjsFixture() throws {
    let fixture = try YjsFixture.load("rich-text-document")
    let doc = YDoc()
    let text = try doc.text(named: "body")

    try doc.apply(.v1(fixture.updateV1))

    try doc.read { transaction in
        try #expect(transaction.chunks(from: text) == [
            YTextChunk(insert: .string("hello"), attributes: ["bold": .bool(true)]),
            YTextChunk(insert: .binary(Data([1, 2, 3])), attributes: [:])
        ])
    }
}
