import Foundation
import SwiftYrs
import Testing

@Test
func subdocumentOpensByGuid() throws {
    let doc = YDoc()
    let map = try doc.map(named: "pages")
    let created = try doc.write { transaction in
        try transaction.setNewSubdoc(forKey: "home", in: map)
    }

    let byGuid = try doc.read { transaction in
        try transaction.subdocDoc(guid: created.guid)
    }
    try #expect(byGuid.guid == created.guid)

    let body = try byGuid.text(named: "body")
    try byGuid.write { transaction in
        try transaction.insert("by guid", into: body, at: 0)
    }

    let byKey = try doc.read { transaction in
        try transaction.subdocDoc(forKey: "home", in: map)
    }
    let byKeyBody = try byKey.text(named: "body")
    try #expect(byKey.read { try $0.string(from: byKeyBody) } == "by guid")
}

@Test
func subdocumentLookupByUnknownGuidThrows() throws {
    let doc = YDoc()
    #expect(throws: YError.typeMismatch) {
        try doc.read { transaction in
            _ = try transaction.subdocDoc(guid: "no-such-guid")
        }
    }
}

@Test
func parentAndSubdocumentUpdateStreamsAreIndependent() throws {
    let doc = YDoc()
    let map = try doc.map(named: "pages")
    try doc.write { transaction in
        _ = try transaction.setNewSubdoc(forKey: "home", in: map)
    }
    let subdoc = try doc.read { transaction in
        try transaction.subdocDoc(forKey: "home", in: map)
    }

    let parentUpdates = Counter()
    let subdocUpdates = Counter()
    let parentObservation = try doc.observeUpdates { _ in parentUpdates.increment() }
    let subdocObservation = try subdoc.observeUpdates { _ in subdocUpdates.increment() }
    defer {
        parentObservation.cancel()
        subdocObservation.cancel()
    }

    let body = try subdoc.text(named: "body")
    try subdoc.write { transaction in
        try transaction.insert("page body", into: body, at: 0)
    }
    #expect(parentUpdates.value == 0)
    #expect(subdocUpdates.value == 1)

    try doc.write { transaction in
        try transaction.set(.string("Vault"), forKey: "title", in: map)
    }
    #expect(parentUpdates.value == 1)
    #expect(subdocUpdates.value == 1)

    // A subdocument inherits the parent's client ID when the transaction that
    // added it commits (yrs transaction.rs:1102), as in Yjs, but it keeps its
    // own state vector and update stream.
    #expect(subdoc.clientID == doc.clientID)
    let parentState = try doc.stateVector()
    let subdocState = try subdoc.stateVector()
    #expect(parentState != subdocState)
}

@Test
func subdocumentReplicatesToASecondDocumentThroughItsOwnUpdate() throws {
    let alice = YDoc()
    let aliceMap = try alice.map(named: "pages")
    let created = try alice.write { transaction in
        try transaction.setNewSubdoc(forKey: "home", in: aliceMap)
    }
    let aliceSubdoc = try alice.read { transaction in
        try transaction.subdocDoc(forKey: "home", in: aliceMap)
    }
    let aliceBody = try aliceSubdoc.text(named: "body")
    try aliceSubdoc.write { transaction in
        try transaction.insert("replicated", into: aliceBody, at: 0)
    }

    let bob = YDoc()
    try bob.apply(alice.encodeStateAsUpdateV1())

    let bobMap = try bob.map(named: "pages")
    try bob.read { transaction in
        try #expect(transaction.subdoc(forKey: "home", in: bobMap).guid == created.guid)
        try #expect(transaction.subdocGuids().contains(created.guid))
    }

    let bobSubdoc = try bob.read { transaction in
        try transaction.subdocDoc(guid: created.guid)
    }
    try #expect(bobSubdoc.guid == created.guid)

    let bobBody = try bobSubdoc.text(named: "body")
    // The parent update carried the entry, never the content.
    try #expect(bobSubdoc.read { try $0.string(from: bobBody) } == "")

    try bobSubdoc.apply(aliceSubdoc.encodeStateAsUpdateV1())
    try #expect(bobSubdoc.read { try $0.string(from: bobBody) } == "replicated")
}

@Test
func heldHandleStaysSafeAfterClearingTheSubdocument() throws {
    let doc = YDoc()
    let map = try doc.map(named: "pages")
    let created = try doc.write { transaction in
        try transaction.setNewSubdoc(forKey: "home", in: map)
    }
    var held: YDoc? = try doc.read { transaction in
        try transaction.subdocDoc(forKey: "home", in: map)
    }
    let heldBody = try #require(held).text(named: "body")
    try #require(held).write { transaction in
        try transaction.insert("before clear", into: heldBody, at: 0)
    }

    let destroyed = Counter()
    let destroyObservation = try #require(held).observeDestroy { event in
        if case .destroy = event { destroyed.increment() }
    }
    defer { destroyObservation.cancel() }

    let subdocEvents = EventLog()
    let subdocObservation = try doc.observeSubdocs { event in
        if case let .subdocs(added, removed, loaded) = event {
            subdocEvents.record(added: added, removed: removed, loaded: loaded)
        }
    }
    defer { subdocObservation.cancel() }

    let parentUpdates = Counter()
    let parentObservation = try doc.observeUpdates { _ in parentUpdates.increment() }
    defer { parentObservation.cancel() }

    let parentStateBeforeWrite = try doc.write { transaction -> YStateVector in
        try transaction.clearSubdoc(forKey: "home", in: map)
        return try transaction.stateVector()
    }

    #expect(destroyed.value == 1)
    #expect(subdocEvents.removed.contains(created.guid))
    // The entry survives the destroy as a fresh, unloaded reference with the
    // same GUID (yrs doc.rs:413), so it is re-announced as added.
    #expect(subdocEvents.added.contains(created.guid))
    try doc.read { transaction in
        try #expect(transaction.subdoc(forKey: "home", in: map).guid == created.guid)
        try #expect(transaction.subdocGuids().contains(created.guid))
    }

    // yrs has no destroyed flag: a write through the held handle succeeds on
    // the detached store and reaches nobody.
    let updatesAfterClear = parentUpdates.value
    try #require(held).write { transaction in
        try transaction.insert("after clear", into: heldBody, at: 0)
    }
    #expect(parentUpdates.value == updatesAfterClear)
    try #expect(doc.stateVector() == parentStateBeforeWrite)
    try #expect(#require(held).read { try $0.string(from: heldBody) } == "after clearbefore clear")

    // Releasing the handle after the clear is safe.
    held = nil
    #expect(held == nil)
}

@Test
func subdocumentHandleOutlivesItsParentDocument() throws {
    func makeHandle() throws -> YDoc {
        let parent = YDoc()
        let map = try parent.map(named: "pages")
        try parent.write { transaction in
            _ = try transaction.setNewSubdoc(forKey: "home", in: map)
        }
        return try parent.read { transaction in
            try transaction.subdocDoc(forKey: "home", in: map)
        }
    }

    let subdoc = try makeHandle()
    let body = try subdoc.text(named: "body")
    try subdoc.write { transaction in
        try transaction.insert("orphan", into: body, at: 0)
    }
    try #expect(subdoc.read { try $0.string(from: body) } == "orphan")
}

@Test
func subdocumentTransactionsNestInsideParentTransactions() throws {
    let doc = YDoc()
    let map = try doc.map(named: "pages")
    try doc.write { transaction in
        _ = try transaction.setNewSubdoc(forKey: "home", in: map)
    }

    // A subdocument write inside a parent read: different documents, so the
    // transaction locks do not conflict.
    try doc.read { parentTransaction in
        let subdoc = try parentTransaction.subdocDoc(forKey: "home", in: map)
        let body = try subdoc.text(named: "body")
        try subdoc.write { subdocTransaction in
            try subdocTransaction.insert("nested", into: body, at: 0)
        }
    }

    // And the reverse: a parent read inside a subdocument write.
    let subdoc = try doc.read { try $0.subdocDoc(forKey: "home", in: map) }
    let body = try subdoc.text(named: "body")
    try subdoc.write { subdocTransaction in
        try subdocTransaction.insert("!", into: body, at: 6)
        try doc.read { parentTransaction in
            try #expect(parentTransaction.subdocGuids().count == 1)
        }
    }
    try #expect(subdoc.read { try $0.string(from: body) } == "nested!")

    // A second transaction on the same document still conflicts.
    try doc.read { _ in
        #expect(throws: YError.transactionConflict) {
            try doc.write { _ in }
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var addedGuids: [String] = []
    private var removedGuids: [String] = []
    private var loadedGuids: [String] = []

    var added: [String] { lock.withLock { addedGuids } }
    var removed: [String] { lock.withLock { removedGuids } }
    var loaded: [String] { lock.withLock { loadedGuids } }

    func record(added: [String], removed: [String], loaded: [String]) {
        lock.withLock {
            addedGuids.append(contentsOf: added)
            removedGuids.append(contentsOf: removed)
            loadedGuids.append(contentsOf: loaded)
        }
    }
}
