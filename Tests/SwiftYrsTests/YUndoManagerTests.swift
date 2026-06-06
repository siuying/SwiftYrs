import Foundation
import Testing
import SwiftYrs

@Test
func undoManagerUndoRedoTextChanges() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    let undoManager = YUndoManager(document: doc)
    try undoManager.addScope(text)

    try doc.write { transaction in
        try transaction.insert("hello", into: text, at: 0)
    }
    #expect(undoManager.undoStackCount == 1)

    #expect(try undoManager.undo())
    try doc.read { transaction in
        try #expect(transaction.string(from: text) == "")
    }

    #expect(try undoManager.redo())
    try doc.read { transaction in
        try #expect(transaction.string(from: text) == "hello")
    }
}

@Test
func undoManagerScopesMapArrayAndXmlChanges() throws {
    let doc = YDoc()
    let map = try doc.map(named: "map")
    let array = try doc.array(named: "array")
    let xml = try doc.xmlFragment(named: "xml")
    let undoManager = YUndoManager(document: doc)
    try undoManager.addScope(map)
    try undoManager.addScope(array)
    try undoManager.addScope(xml)

    try doc.write { transaction in
        try transaction.set(.string("value"), forKey: "key", in: map)
        try transaction.insert(.string("item"), into: array, at: 0)
        _ = try transaction.insertElement(named: "p", into: xml, at: 0)
    }

    #expect(undoManager.undoStackCount == 1)
    #expect(try undoManager.undo())

    try doc.read { transaction in
        try #expect(transaction.get("key", from: map) == .undefined)
        try #expect(transaction.count(of: array) == 0)
        try #expect(transaction.childCount(of: xml) == 0)
    }

    #expect(try undoManager.redo())
    try doc.read { transaction in
        try #expect(transaction.get("key", from: map) == .string("value"))
        try #expect(transaction.count(of: array) == 1)
        try #expect(transaction.childCount(of: xml) == 1)
    }
}

@Test
func undoManagerCanSplitAndClearStacks() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    let undoManager = YUndoManager(document: doc)
    try undoManager.addScope(text)

    try doc.write { transaction in
        try transaction.insert("a", into: text, at: 0)
    }
    undoManager.stopCapturing()
    try doc.write { transaction in
        try transaction.insert("b", into: text, at: 1)
    }

    #expect(undoManager.undoStackCount == 2)
    #expect(try undoManager.undo())
    try doc.read { transaction in
        try #expect(transaction.string(from: text) == "a")
    }
    #expect(undoManager.redoStackCount == 1)
    undoManager.clear()
    #expect(undoManager.undoStackCount == 0)
    #expect(undoManager.redoStackCount == 0)
}

@Test
func undoManagerCanFilterTrackedOrigins() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    let undoManager = YUndoManager(document: doc)
    try undoManager.addScope(text)
    undoManager.includeOrigin("tracked")

    try doc.write(origin: "ignored") { transaction in
        try transaction.insert("x", into: text, at: 0)
    }
    #expect(undoManager.undoStackCount == 0)

    try doc.write(origin: "tracked") { transaction in
        try transaction.insert("y", into: text, at: 1)
    }
    #expect(undoManager.undoStackCount == 1)
    #expect(try undoManager.undo())
    try doc.read { transaction in
        try #expect(transaction.string(from: text) == "x")
    }
}

@Test
func undoManagerObservationDeliversAddedAndPoppedEvents() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    let undoManager = YUndoManager(document: doc)
    try undoManager.addScope(text)
    var events: [YObservationEvent] = []

    let added = try undoManager.observeItemAdded { events.append($0) }
    let popped = try undoManager.observeItemPopped { events.append($0) }
    defer {
        added.cancel()
        popped.cancel()
    }

    try doc.write { transaction in
        try transaction.insert("hello", into: text, at: 0)
    }
    _ = try undoManager.undo()

    #expect(events.map(\.kind) == ["undoItemAdded", "undoItemAdded", "undoItemPopped"])
    #expect(events.map { $0.object["action"] as? String } == ["undo", "redo", "undo"])
}
