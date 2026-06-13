import Foundation
import SQLite
import SwiftYrs
@testable import SwiftYrsSQLite
import Testing

@Test
func providerPersistsUpdatesAcrossProviderInstances() throws {
    let databaseURL = try temporaryDatabaseURL()
    let store = try SQLiteStore(Connection(databaseURL.path))

    let firstDoc = YDoc()
    let firstProvider = SQLiteProvider(documentName: "chat-demo", doc: firstDoc, store: store)
    try firstProvider.start()

    let firstText = try firstDoc.text(named: "body")
    try firstDoc.write { transaction in
        try transaction.insert("hello", into: firstText, at: 0)
    }
    firstProvider.destroy()

    let secondDoc = YDoc()
    let secondProvider = SQLiteProvider(documentName: "chat-demo", doc: secondDoc, store: store)
    try secondProvider.start()
    defer { secondProvider.destroy() }

    let secondText = try secondDoc.text(named: "body")
    let value = try secondDoc.read { transaction in
        try transaction.string(from: secondText)
    }
    #expect(value == "hello")
}

@Test
func storeServesMultipleDocumentsAndRejectsDuplicateActiveProvider() throws {
    let databaseURL = try temporaryDatabaseURL()
    let store = try SQLiteStore(Connection(databaseURL.path))

    let firstDoc = YDoc()
    let firstProvider = SQLiteProvider(documentName: "a", doc: firstDoc, store: store)
    try firstProvider.start()
    defer { firstProvider.destroy() }

    let secondDoc = YDoc()
    let secondProvider = SQLiteProvider(documentName: "b", doc: secondDoc, store: store)
    try secondProvider.start()
    defer { secondProvider.destroy() }

    #expect(firstProvider.isStarted)
    try firstProvider.start()
    #expect(firstProvider.isStarted)

    let duplicate = SQLiteProvider(documentName: "a", doc: YDoc(), store: store)
    #expect(throws: SQLiteProviderError.duplicateProvider(documentName: "a")) {
        try duplicate.start()
    }

    try insert("one", into: firstDoc, named: "body")
    try insert("two", into: secondDoc, named: "body")
    firstProvider.destroy()
    secondProvider.destroy()
    #expect(throws: SQLiteProviderError.destroyed) {
        try firstProvider.start()
    }

    let reloadedA = YDoc()
    let providerA = SQLiteProvider(documentName: "a", doc: reloadedA, store: store)
    try providerA.start()
    defer { providerA.destroy() }
    #expect(try string(in: reloadedA, named: "body") == "one")

    let reloadedB = YDoc()
    let providerB = SQLiteProvider(documentName: "b", doc: reloadedB, store: store)
    try providerB.start()
    defer { providerB.destroy() }
    #expect(try string(in: reloadedB, named: "body") == "two")
}

@Test
func metadataIsScopedByDocumentNameAndDoesNotMutateTheDocument() throws {
    let databaseURL = try temporaryDatabaseURL()
    let connection = try Connection(databaseURL.path)
    let store = try SQLiteStore(connection)

    let first = SQLiteProvider(documentName: "a", doc: YDoc(), store: store)
    try first.start()
    try first.setMetadata(Data("alice".utf8), forKey: "lastOpenedBy")
    try first.setMetadata(Data(), forKey: "empty")
    first.destroy()

    let second = SQLiteProvider(documentName: "b", doc: YDoc(), store: store)
    try second.start()
    defer { second.destroy() }
    try second.setMetadata(Data("bob".utf8), forKey: "lastOpenedBy")

    let reloadedDoc = YDoc()
    let reloaded = SQLiteProvider(documentName: "a", doc: reloadedDoc, store: store)
    try reloaded.start()
    defer { reloaded.destroy() }

    #expect(try reloaded.metadata(forKey: "lastOpenedBy") == Data("alice".utf8))
    #expect(try reloaded.metadata(forKey: "empty") == Data())
    #expect(try reloaded.metadata(forKey: "missing") == nil)
    try reloaded.removeMetadata(forKey: "lastOpenedBy")
    #expect(try reloaded.metadata(forKey: "lastOpenedBy") == nil)
    #expect(try string(in: reloadedDoc, named: "body") == "")
    #expect(try updateRowCount(store, documentName: "a") == 0)
}

@Test
func compactionRewritesUpdatesToSnapshotAndKeepsAcceptingUpdates() throws {
    let databaseURL = try temporaryDatabaseURL()
    let connection = try Connection(databaseURL.path)
    let store = try SQLiteStore(connection)
    let options = try SQLiteProviderOptions(autoCompact: true, compactThreshold: 2)

    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "compact", doc: doc, store: store, options: options)
    try provider.start()
    try provider.setMetadata(Data("value".utf8), forKey: "key")
    try insert("a", into: doc, named: "body")
    try insert("b", into: doc, named: "body")
    try waitUntil {
        try updateRowCount(store, documentName: "compact") == 1
    }
    #expect(try updateKinds(store, documentName: "compact") == ["snapshot"])
    provider.destroy()

    let reloadedDoc = YDoc()
    let manualCompaction = try SQLiteProviderOptions(autoCompact: false, compactThreshold: 2)
    let reloaded = SQLiteProvider(documentName: "compact", doc: reloadedDoc, store: store, options: manualCompaction)
    try reloaded.start()
    try insert("c", into: reloadedDoc, named: "body")
    try reloaded.compact()
    defer { reloaded.destroy() }

    #expect(try string(in: reloadedDoc, named: "body") == "abc")
    #expect(try reloaded.metadata(forKey: "key") == Data("value".utf8))
    #expect(try updateRowCount(store, documentName: "compact") == 1)
}

@Test
func compactionPreservesRowsWrittenAfterCapturedBoundary() throws {
    let databaseURL = try temporaryDatabaseURL()
    let connection = try Connection(databaseURL.path)
    let store = try SQLiteStore(connection)

    let doc = YDoc()
    try insert("a", into: doc, named: "body")
    let snapshot = try doc.encodeStateAsUpdateV1()
    let compactedThroughID = try store.sync { connection -> Int64? in
        try SQLiteSchema.create(on: connection)
        try SQLiteSchema.append(snapshot, kind: .incremental, documentName: "race", on: connection)
        return try SQLiteSchema.maxUpdateID(documentName: "race", on: connection)
    }
    guard let compactedThroughID else {
        Issue.record("Expected an update row before compaction")
        return
    }

    try insert("b", into: doc, named: "body")
    let laterUpdate = try doc.encodeStateAsUpdateV1()
    try store.sync { connection in
        try SQLiteSchema.append(laterUpdate, kind: .incremental, documentName: "race", on: connection)
        try SQLiteSchema.compact(
            documentName: "race",
            snapshot: snapshot,
            compactedThroughID: compactedThroughID,
            on: connection
        )
    }

    #expect(try updateRowCount(store, documentName: "race") == 2)
    #expect(try updateKinds(store, documentName: "race") == ["incremental", "snapshot"])

    let reloadedDoc = YDoc()
    let reloaded = SQLiteProvider(documentName: "race", doc: reloadedDoc, store: store)
    try reloaded.start()
    defer { reloaded.destroy() }
    #expect(try string(in: reloadedDoc, named: "body") == "ab")
}

@Test
func startDoesNotAutoCompactExistingRows() throws {
    let databaseURL = try temporaryDatabaseURL()
    let connection = try Connection(databaseURL.path)
    let store = try SQLiteStore(connection)
    let noAutoCompact = try SQLiteProviderOptions(autoCompact: false, compactThreshold: 2)

    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "history", doc: doc, store: store, options: noAutoCompact)
    try provider.start()
    try insert("a", into: doc, named: "body")
    try insert("b", into: doc, named: "body")
    try insert("c", into: doc, named: "body")
    provider.destroy()
    #expect(try updateRowCount(store, documentName: "history") == 3)

    let compactingOptions = try SQLiteProviderOptions(autoCompact: true, compactThreshold: 2)
    let reloaded = SQLiteProvider(documentName: "history", doc: YDoc(), store: store, options: compactingOptions)
    try reloaded.start()
    defer { reloaded.destroy() }

    #expect(try updateRowCount(store, documentName: "history") == 3)
}

@Test
func compactThresholdMustBePositive() {
    #expect(throws: SQLiteProviderError.invalidCompactThreshold(0)) {
        _ = try SQLiteProviderOptions(compactThreshold: 0)
    }
}

@Test
func storeCanCreateSchemaAndRemoveInactiveDocuments() throws {
    let databaseURL = try temporaryDatabaseURL()
    let connection = try Connection(databaseURL.path)
    let store = try SQLiteStore(connection)
    try store.createSchemaIfNeeded()
    try connection.run("CREATE TABLE app_owned_table (id INTEGER PRIMARY KEY)")

    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "remove-me", doc: doc, store: store)
    try provider.start()
    try provider.setMetadata(Data("metadata".utf8), forKey: "key")
    try insert("hello", into: doc, named: "body")
    #expect(throws: SQLiteProviderError.activeProvider(documentName: "remove-me")) {
        try store.removeDocument(named: "remove-me")
    }
    provider.destroy()

    try store.removeDocument(named: "remove-me")
    #expect(try updateRowCount(store, documentName: "remove-me") == 0)
    #expect(try metadataRowCount(store, documentName: "remove-me") == 0)
    #expect(try scalarCount(connection, sql: "SELECT count(*) FROM app_owned_table") == 0)
}

@Test
func startupRejectsInvalidPersistedRows() throws {
    try assertInvalidPersistedRow(
        updateEncoding: "v2",
        updateKind: "incremental",
        update: Data([0, 0])
    ) { error in
        error as? SQLiteProviderError == .unknownUpdateEncoding("v2")
    }

    try assertInvalidPersistedRow(
        updateEncoding: "v1",
        updateKind: "future",
        update: Data([0, 0])
    ) { error in
        error as? SQLiteProviderError == .unknownUpdateKind("future")
    }

    try assertInvalidPersistedRow(
        updateEncoding: "v1",
        updateKind: "incremental",
        update: Data()
    ) { error in
        error as? SQLiteProviderError == .emptyUpdateBlob
    }

    try assertInvalidPersistedRow(
        updateEncoding: "v1",
        updateKind: "incremental",
        update: Data([0xff])
    ) { error in
        error as? YError == .decodeFailure
    }
}

private func temporaryDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftYrsSQLiteTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("db.sqlite")
}

private func insert(_ value: String, into doc: YDoc, named name: String) throws {
    let text = try doc.text(named: name)
    let length = try doc.read { transaction in
        try transaction.length(of: text)
    }
    try doc.write { transaction in
        try transaction.insert(value, into: text, at: length)
    }
}

private func string(in doc: YDoc, named name: String) throws -> String {
    let text = try doc.text(named: name)
    return try doc.read { transaction in
        try transaction.string(from: text)
    }
}

private func updateRowCount(_ connection: Connection, documentName: String) throws -> Int {
    try scalarCount(
        connection,
        sql: "SELECT count(*) FROM swiftyrs_sqlite_updates WHERE document_name = ?",
        documentName
    )
}

private func updateRowCount(_ store: SQLiteStore, documentName: String) throws -> Int {
    try store.sync { connection in
        try updateRowCount(connection, documentName: documentName)
    }
}

private func updateKinds(_ connection: Connection, documentName: String) throws -> [String] {
    try connection.prepare(
        "SELECT update_kind FROM swiftyrs_sqlite_updates WHERE document_name = ? ORDER BY id",
        documentName
    ).map { row in
        row[0] as? String ?? ""
    }
}

private func updateKinds(_ store: SQLiteStore, documentName: String) throws -> [String] {
    try store.sync { connection in
        try updateKinds(connection, documentName: documentName)
    }
}

private func metadataRowCount(_ connection: Connection, documentName: String) throws -> Int {
    try scalarCount(
        connection,
        sql: "SELECT count(*) FROM swiftyrs_sqlite_metadata WHERE document_name = ?",
        documentName
    )
}

private func metadataRowCount(_ store: SQLiteStore, documentName: String) throws -> Int {
    try store.sync { connection in
        try metadataRowCount(connection, documentName: documentName)
    }
}

private func scalarCount(_ connection: Connection, sql: String, _ bindings: Binding?...) throws -> Int {
    let statement = try connection.prepare(sql, bindings)
    guard let row = try statement.run().makeIterator().next() else {
        return 0
    }
    return Int((row[0] as? Int64) ?? 0)
}

private func assertInvalidPersistedRow(
    updateEncoding: String,
    updateKind: String,
    update: Data,
    matches: (Error) -> Bool
) throws {
    let databaseURL = try temporaryDatabaseURL()
    let connection = try Connection(databaseURL.path)
    let store = try SQLiteStore(connection)
    try store.createSchemaIfNeeded()
    try connection.run(
        """
        INSERT INTO swiftyrs_sqlite_updates
            (document_name, update_encoding, update_kind, "update", inserted_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        "bad",
        updateEncoding,
        updateKind,
        Blob(bytes: Array(update)),
        Date().timeIntervalSince1970
    )

    let provider = SQLiteProvider(documentName: "bad", doc: YDoc(), store: store)
    do {
        try provider.start()
        Issue.record("Expected invalid persisted row to throw")
    } catch {
        #expect(matches(error))
    }
}

private func waitUntil(
    timeout: TimeInterval = 2,
    interval: TimeInterval = 0.01,
    condition: () throws -> Bool
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() {
            return
        }
        Thread.sleep(forTimeInterval: interval)
    }
    #expect(try condition())
}
