import Foundation
import SwiftYrsSQLite

public protocol CloudKitMetadataStore: Sendable {
    func set(_ value: Data, forKey key: String, documentName: String) throws
    func data(forKey key: String, documentName: String) throws -> Data?
    func removeData(forKey key: String, documentName: String) throws
}

public final class FileCloudKitMetadataStore: CloudKitMetadataStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public func set(_ value: Data, forKey key: String, documentName: String) throws {
        try lock.withLock {
            let documentDirectory = documentDirectory(for: documentName)
            try fileManager.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
            try value.write(to: fileURL(forKey: key, documentName: documentName), options: .atomic)
        }
    }

    public func data(forKey key: String, documentName: String) throws -> Data? {
        try lock.withLock {
            let url = fileURL(forKey: key, documentName: documentName)
            guard fileManager.fileExists(atPath: url.path) else {
                return nil
            }
            return try Data(contentsOf: url)
        }
    }

    public func removeData(forKey key: String, documentName: String) throws {
        try lock.withLock {
            let url = fileURL(forKey: key, documentName: documentName)
            guard fileManager.fileExists(atPath: url.path) else {
                return
            }
            try fileManager.removeItem(at: url)
        }
    }

    private func documentDirectory(for documentName: String) -> URL {
        directory.appendingPathComponent(Self.pathComponent(for: documentName), isDirectory: true)
    }

    private func fileURL(forKey key: String, documentName: String) -> URL {
        documentDirectory(for: documentName)
            .appendingPathComponent(Self.pathComponent(for: key), isDirectory: false)
    }

    private static func pathComponent(for value: String) -> String {
        let encoded = Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded.isEmpty ? "_" : encoded
    }
}

public final class SQLiteCloudKitMetadataStore: CloudKitMetadataStore, @unchecked Sendable {
    public static let keyPrefix = "cloudkit."

    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    public func set(_ value: Data, forKey key: String, documentName: String) throws {
        try store.setMetadata(value, forKey: namespaced(key), documentName: documentName)
    }

    public func data(forKey key: String, documentName: String) throws -> Data? {
        try store.metadata(forKey: namespaced(key), documentName: documentName)
    }

    public func removeData(forKey key: String, documentName: String) throws {
        try store.removeMetadata(forKey: namespaced(key), documentName: documentName)
    }

    private func namespaced(_ key: String) -> String {
        Self.keyPrefix + key
    }
}
