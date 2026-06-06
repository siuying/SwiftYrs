import Foundation
import Testing
import SwiftYrs

@Test
func textSupportsInsertRemoveLengthAndStringReads() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")

    try doc.write { transaction in
        try transaction.insert("hello", into: text, at: 0)
        try transaction.insert(" world", into: text, at: 5)
        try #expect(transaction.length(of: text) == 11)
        try #expect(transaction.string(from: text) == "hello world")

        try transaction.remove(from: text, at: 5, length: 1)
        try #expect(transaction.string(from: text) == "helloworld")
    }
}

@Test
func mapSupportsMixedScalarBinaryValuesAndRemoval() throws {
    let doc = YDoc()
    let map = try doc.map(named: "meta")
    let bytes = Data([1, 2, 3])

    try doc.write { transaction in
        try transaction.set(.string("Ada"), forKey: "name", in: map)
        try transaction.set(.int(42), forKey: "count", in: map)
        try transaction.set(.bool(true), forKey: "enabled", in: map)
        try transaction.set(.null, forKey: "nothing", in: map)
        try transaction.set(.binary(bytes), forKey: "bytes", in: map)

        try #expect(transaction.get("name", from: map) == .string("Ada"))
        try #expect(transaction.get("count", from: map) == .int(42))
        try #expect(transaction.get("enabled", from: map) == .bool(true))
        try #expect(transaction.get("nothing", from: map) == .null)
        try #expect(transaction.get("bytes", from: map) == .binary(bytes))

        try transaction.remove("enabled", from: map)
        try #expect(transaction.get("enabled", from: map) == .undefined)
    }
}

@Test
func arraySupportsMixedValuesIterationAndRemoval() throws {
    let doc = YDoc()
    let array = try doc.array(named: "items")

    try doc.write { transaction in
        try transaction.insert(.string("first"), into: array, at: 0)
        try transaction.insert(.double(2.5), into: array, at: 1)
        try transaction.insert(.binary(Data([9, 8])), into: array, at: 2)

        try #expect(transaction.count(of: array) == 3)
        try #expect(transaction.get(0, from: array) == .string("first"))
        try #expect(transaction.get(1, from: array) == .double(2.5))
        try #expect(transaction.get(2, from: array) == .binary(Data([9, 8])))

        let json = try transaction.valuesJSON(from: array)
        #expect(json.count == 3)

        try transaction.remove(from: array, at: 1, length: 1)
        try #expect(transaction.count(of: array) == 2)
        try #expect(transaction.get(1, from: array) == .binary(Data([9, 8])))
    }
}

@Test
func containersCanHoldNestedSharedTypes() throws {
    let doc = YDoc()
    let text = try doc.text(named: "title")
    let array = try doc.array(named: "refs")
    let map = try doc.map(named: "refs")

    try doc.write { transaction in
        try transaction.insert("Nested", into: text, at: 0)
        try transaction.insert(.text(text), into: array, at: 0)
        try transaction.set(.text(text), forKey: "title", in: map)

        guard case let .text(arrayText) = try transaction.get(0, from: array) else {
            Issue.record("Expected nested YText in array")
            return
        }
        guard case let .text(mapText) = try transaction.get("title", from: map) else {
            Issue.record("Expected nested YText in map")
            return
        }

        try #expect(transaction.string(from: arrayText) == "Nested")
        try #expect(transaction.string(from: mapText) == "Nested")
    }
}

@Test
func containerContentRoundtripsThroughDocumentUpdates() throws {
    let source = YDoc()
    let destination = YDoc()
    let sourceText = try source.text(named: "body")
    let destinationText = try destination.text(named: "body")

    try source.write { transaction in
        try transaction.insert("synced", into: sourceText, at: 0)
    }

    try destination.apply(try source.encodeStateAsUpdateV1())

    try destination.read { transaction in
        try #expect(transaction.string(from: destinationText) == "synced")
    }
}
