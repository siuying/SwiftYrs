import Foundation
import Testing
@testable import SwiftYrs

@Suite
struct YNestedContainerTests {
    @Test
    func insertNestedMapIntoArrayAndReadBack() throws {
        let doc = YDoc()
        let array = try doc.array(named: "items")

        try doc.write { transaction in
            let nested = try transaction.insertMap(into: array, at: 0)
            try transaction.set(.string("alice"), forKey: "sender", in: nested)

            #expect(try transaction.count(of: array) == 1)
            guard case let .map(readBack) = try transaction.get(0, from: array) else {
                Issue.record("Expected a nested YMap at array index 0")
                return
            }
            #expect(try transaction.get("sender", from: readBack) == .string("alice"))
        }
    }

    @Test
    func insertNestedArrayIntoArrayAndReadBack() throws {
        let doc = YDoc()
        let array = try doc.array(named: "items")

        try doc.write { transaction in
            let nested = try transaction.insertArray(into: array, at: 0)
            try transaction.insert(.int(1), into: nested, at: 0)
            try transaction.insert(.int(2), into: nested, at: 1)

            guard case let .array(readBack) = try transaction.get(0, from: array) else {
                Issue.record("Expected a nested YArray at array index 0")
                return
            }
            #expect(try transaction.count(of: readBack) == 2)
            #expect(try transaction.get(0, from: readBack) == .int(1))
            #expect(try transaction.get(1, from: readBack) == .int(2))
        }
    }

    @Test
    func setNestedMapIntoMapAndReadBack() throws {
        let doc = YDoc()
        let map = try doc.map(named: "root")

        try doc.write { transaction in
            let nested = try transaction.setMap(forKey: "profile", in: map)
            try transaction.set(.string("bob"), forKey: "name", in: nested)

            guard case let .map(readBack) = try transaction.get("profile", from: map) else {
                Issue.record("Expected a nested YMap under key 'profile'")
                return
            }
            #expect(try transaction.get("name", from: readBack) == .string("bob"))
        }
    }

    @Test
    func setNestedArrayIntoMapAndReadBack() throws {
        let doc = YDoc()
        let map = try doc.map(named: "root")

        try doc.write { transaction in
            let nested = try transaction.setArray(forKey: "tags", in: map)
            try transaction.insert(.string("x"), into: nested, at: 0)

            guard case let .array(readBack) = try transaction.get("tags", from: map) else {
                Issue.record("Expected a nested YArray under key 'tags'")
                return
            }
            #expect(try transaction.get(0, from: readBack) == .string("x"))
        }
    }

    @Test
    func nestedMapSurvivesUpdateRoundtrip() throws {
        let source = YDoc()
        let destination = YDoc()
        let sourceArray = try source.array(named: "items")
        let destinationArray = try destination.array(named: "items")

        try source.write { transaction in
            let nested = try transaction.insertMap(into: sourceArray, at: 0)
            try transaction.set(.string("alice"), forKey: "sender", in: nested)
            try transaction.set(.string("hello"), forKey: "body", in: nested)
        }

        try destination.apply(try source.encodeStateAsUpdateV1())

        try destination.read { transaction in
            guard case let .map(readBack) = try transaction.get(0, from: destinationArray) else {
                Issue.record("Expected a nested YMap to survive the update roundtrip")
                return
            }
            #expect(try transaction.get("sender", from: readBack) == .string("alice"))
            #expect(try transaction.get("body", from: readBack) == .string("hello"))
        }
    }

    @Test
    func nestedMapIsLiveAcrossTransactions() throws {
        let source = YDoc()
        let destination = YDoc()
        let sourceArray = try source.array(named: "items")
        let destinationArray = try destination.array(named: "items")

        // Insert an empty nested map and keep the live handle.
        let nested = try source.write { transaction in
            try transaction.insertMap(into: sourceArray, at: 0)
        }

        // Mutate it in a *separate later* transaction — only possible if it is a
        // live integrated branch, not an immutable Any snapshot.
        try source.write { transaction in
            try transaction.set(.string("late"), forKey: "body", in: nested)
        }

        try destination.apply(try source.encodeStateAsUpdateV1())

        try destination.read { transaction in
            guard case let .map(readBack) = try transaction.get(0, from: destinationArray) else {
                Issue.record("Expected a nested YMap to survive the update roundtrip")
                return
            }
            #expect(try transaction.get("body", from: readBack) == .string("late"))
        }
    }

    @Test
    func nestedContainersCanApplyJavaScriptYjsFixture() throws {
        let fixture = try YjsFixture.load("nested-container-document")
        let doc = YDoc()
        let messages = try doc.array(named: "messages")

        try doc.apply(.v1(fixture.updateV1))

        try doc.read { transaction in
            #expect(try transaction.count(of: messages) == 1)
            guard case let .map(message) = try transaction.get(0, from: messages) else {
                Issue.record("Expected a nested YMap message from the Yjs fixture")
                return
            }
            #expect(try transaction.get("sender", from: message) == .string("alice"))
            #expect(try transaction.get("body", from: message) == .string("hello"))

            guard case let .array(tags) = try transaction.get("tags", from: message) else {
                Issue.record("Expected a nested YArray under 'tags' from the Yjs fixture")
                return
            }
            #expect(try transaction.count(of: tags) == 2)
            #expect(try transaction.get(0, from: tags) == .string("urgent"))
            #expect(try transaction.get(1, from: tags) == .string("demo"))
        }
    }

    @Test
    func insertNestedTextIntoArrayAndReadBack() throws {
        let doc = YDoc()
        let array = try doc.array(named: "items")

        try doc.write { transaction in
            let nested = try transaction.insertText(into: array, at: 0)
            try transaction.insert("hi", into: nested, at: 0)

            guard case let .text(readBack) = try transaction.get(0, from: array) else {
                Issue.record("Expected a nested YText at array index 0")
                return
            }
            #expect(try transaction.string(from: readBack) == "hi")
        }
    }

    @Test
    func setNestedTextIntoMapAndReadBack() throws {
        let doc = YDoc()
        let map = try doc.map(named: "root")

        try doc.write { transaction in
            let nested = try transaction.setText(forKey: "note", in: map)
            try transaction.insert("yo", into: nested, at: 0)

            guard case let .text(readBack) = try transaction.get("note", from: map) else {
                Issue.record("Expected a nested YText under key 'note'")
                return
            }
            #expect(try transaction.string(from: readBack) == "yo")
        }
    }
}
