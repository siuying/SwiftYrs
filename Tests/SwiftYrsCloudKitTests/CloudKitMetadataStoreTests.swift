import Foundation
import SQLite
import SwiftYrsCloudKit
import SwiftYrsSQLite
import Testing

@Test
func fileMetadataStoreRoundTripsDataScopedByDocumentAndKey() throws {
    let store = FileCloudKitMetadataStore(directory: try temporaryDirectory())

    try store.set(Data("alice".utf8), forKey: "engineState", documentName: "doc-a")
    try store.set(Data("bob".utf8), forKey: "engineState", documentName: "doc-b")
    try store.set(Data(), forKey: "empty", documentName: "doc-a")

    #expect(try store.data(forKey: "engineState", documentName: "doc-a") == Data("alice".utf8))
    #expect(try store.data(forKey: "engineState", documentName: "doc-b") == Data("bob".utf8))
    #expect(try store.data(forKey: "empty", documentName: "doc-a") == Data())
    #expect(try store.data(forKey: "missing", documentName: "doc-a") == nil)

    try store.removeData(forKey: "engineState", documentName: "doc-a")
    #expect(try store.data(forKey: "engineState", documentName: "doc-a") == nil)
    #expect(try store.data(forKey: "engineState", documentName: "doc-b") == Data("bob".utf8))
}

@Test
func sqliteMetadataStoreRoundTripsDataUnderCloudKitNamespace() throws {
    let sqliteStore = try SQLiteStore(Connection(try temporaryDatabaseURL().path))
    let store = SQLiteCloudKitMetadataStore(store: sqliteStore)

    try store.set(Data("alice".utf8), forKey: "engineState", documentName: "doc-a")
    try store.set(Data("bob".utf8), forKey: "engineState", documentName: "doc-b")
    try store.set(Data(), forKey: "empty", documentName: "doc-a")

    #expect(try store.data(forKey: "engineState", documentName: "doc-a") == Data("alice".utf8))
    #expect(try store.data(forKey: "engineState", documentName: "doc-b") == Data("bob".utf8))
    #expect(try store.data(forKey: "empty", documentName: "doc-a") == Data())
    #expect(try store.data(forKey: "missing", documentName: "doc-a") == nil)

    #expect(
        try sqliteStore.metadata(forKey: "cloudkit.engineState", documentName: "doc-a")
            == Data("alice".utf8)
    )
    #expect(try sqliteStore.metadata(forKey: "engineState", documentName: "doc-a") == nil)

    try store.removeData(forKey: "engineState", documentName: "doc-a")
    #expect(try store.data(forKey: "engineState", documentName: "doc-a") == nil)
    #expect(try store.data(forKey: "engineState", documentName: "doc-b") == Data("bob".utf8))
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftYrsCloudKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func temporaryDatabaseURL() throws -> URL {
    try temporaryDirectory().appendingPathComponent("db.sqlite")
}
