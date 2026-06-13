#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs

public enum CloudKitRecordCodecError: Error, Equatable {
    case missingField(String)
    case invalidField(String)
    case unsupportedUpdateEncoding(String)
    case missingAssetFile(String)
}

public enum CloudKitRecordType {
    public static let incremental = "SwiftYrsIncrementalUpdate"
    public static let snapshot = "SwiftYrsSnapshot"
}

public enum CloudKitRecordField {
    public static let documentName = "documentName"
    public static let clientID = "clientID"
    public static let fromClock = "fromClock"
    public static let toClock = "toClock"
    public static let updateEncoding = "updateEncoding"
    public static let inlineUpdate = "inlineUpdate"
    public static let assetUpdate = "assetUpdate"
    public static let snapshotUpdate = "snapshotUpdate"
    public static let stateVector = "stateVector"
}

public struct CloudKitIncrementalRecordPayload: Equatable, Sendable {
    public let documentName: String
    public let clientID: UInt64
    public let fromClock: UInt32
    public let toClock: UInt32
    public let update: YUpdate

    public init(
        documentName: String,
        clientID: UInt64,
        fromClock: UInt32,
        toClock: UInt32,
        update: YUpdate
    ) {
        self.documentName = documentName
        self.clientID = clientID
        self.fromClock = fromClock
        self.toClock = toClock
        self.update = update
    }
}

public struct CloudKitSnapshotRecordPayload: Equatable, Sendable {
    public let documentName: String
    public let update: YUpdate
    public let stateVector: YStateVector

    public init(documentName: String, update: YUpdate, stateVector: YStateVector) {
        self.documentName = documentName
        self.update = update
        self.stateVector = stateVector
    }
}

public struct CloudKitRecordCodec: Sendable {
    public static let defaultInlineBytesLimit = 900_000

    public let assetDirectory: URL
    public let inlineBytesLimit: Int

    public init(assetDirectory: URL, inlineBytesLimit: Int = Self.defaultInlineBytesLimit) {
        self.assetDirectory = assetDirectory
        self.inlineBytesLimit = inlineBytesLimit
    }

    public func zoneID(forDocumentName documentName: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "swiftyrs.\(Self.encodedComponent(documentName))")
    }

    public func incrementalRecordID(
        documentName: String,
        clientID: UInt64,
        fromClock: UInt32,
        toClock: UInt32
    ) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "incremental.\(clientID).\(fromClock).\(toClock)",
            zoneID: zoneID(forDocumentName: documentName)
        )
    }

    public func snapshotRecordID(documentName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "snapshot", zoneID: zoneID(forDocumentName: documentName))
    }

    public func encodeIncremental(_ payload: CloudKitIncrementalRecordPayload) throws -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitRecordType.incremental,
            recordID: incrementalRecordID(
                documentName: payload.documentName,
                clientID: payload.clientID,
                fromClock: payload.fromClock,
                toClock: payload.toClock
            )
        )
        record[CloudKitRecordField.documentName] = payload.documentName as NSString
        record[CloudKitRecordField.clientID] = String(payload.clientID) as NSString
        record[CloudKitRecordField.fromClock] = NSNumber(value: payload.fromClock)
        record[CloudKitRecordField.toClock] = NSNumber(value: payload.toClock)
        record[CloudKitRecordField.updateEncoding] = encodingName(payload.update.encoding) as NSString

        if payload.update.data.count <= inlineBytesLimit {
            record[CloudKitRecordField.inlineUpdate] = payload.update.data as NSData
        } else {
            record[CloudKitRecordField.assetUpdate] = try asset(for: payload.update.data)
        }

        return record
    }

    public func decodeIncremental(_ record: CKRecord) throws -> CloudKitIncrementalRecordPayload {
        let documentName = try stringField(CloudKitRecordField.documentName, from: record)
        let clientIDValue = try stringField(CloudKitRecordField.clientID, from: record)
        guard let clientID = UInt64(clientIDValue) else {
            throw CloudKitRecordCodecError.invalidField(CloudKitRecordField.clientID)
        }
        let fromClock = try uint32Field(CloudKitRecordField.fromClock, from: record)
        let toClock = try uint32Field(CloudKitRecordField.toClock, from: record)
        let encoding = try updateEncoding(from: record)
        let updateData = try updateData(
            inlineField: CloudKitRecordField.inlineUpdate,
            assetField: CloudKitRecordField.assetUpdate,
            from: record
        )
        return CloudKitIncrementalRecordPayload(
            documentName: documentName,
            clientID: clientID,
            fromClock: fromClock,
            toClock: toClock,
            update: YUpdate(updateData, encoding: encoding)
        )
    }

    public func encodeSnapshot(_ payload: CloudKitSnapshotRecordPayload) throws -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitRecordType.snapshot,
            recordID: snapshotRecordID(documentName: payload.documentName)
        )
        record[CloudKitRecordField.documentName] = payload.documentName as NSString
        record[CloudKitRecordField.updateEncoding] = encodingName(payload.update.encoding) as NSString
        record[CloudKitRecordField.snapshotUpdate] = try asset(for: payload.update.data)
        record[CloudKitRecordField.stateVector] = payload.stateVector.data as NSData
        return record
    }

    public func decodeSnapshot(_ record: CKRecord) throws -> CloudKitSnapshotRecordPayload {
        let documentName = try stringField(CloudKitRecordField.documentName, from: record)
        let encoding = try updateEncoding(from: record)
        let updateData = try updateData(
            inlineField: nil,
            assetField: CloudKitRecordField.snapshotUpdate,
            from: record
        )
        let stateVector = try dataField(CloudKitRecordField.stateVector, from: record)
        return CloudKitSnapshotRecordPayload(
            documentName: documentName,
            update: YUpdate(updateData, encoding: encoding),
            stateVector: YStateVector(stateVector)
        )
    }

    private func asset(for data: Data) throws -> CKAsset {
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        let url = assetDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return CKAsset(fileURL: url)
    }

    private func updateData(inlineField: String?, assetField: String, from record: CKRecord) throws -> Data {
        if let inlineField, let data = try optionalDataField(inlineField, from: record) {
            return data
        }
        guard let asset = record[assetField] as? CKAsset else {
            throw CloudKitRecordCodecError.missingField(assetField)
        }
        guard let fileURL = asset.fileURL else {
            throw CloudKitRecordCodecError.missingAssetFile(assetField)
        }
        return try Data(contentsOf: fileURL)
    }

    private func updateEncoding(from record: CKRecord) throws -> YUpdate.Encoding {
        let value = try stringField(CloudKitRecordField.updateEncoding, from: record)
        switch value {
        case "v1":
            return .v1
        case "v2":
            return .v2
        default:
            throw CloudKitRecordCodecError.unsupportedUpdateEncoding(value)
        }
    }

    private func encodingName(_ encoding: YUpdate.Encoding) -> String {
        switch encoding {
        case .v1:
            return "v1"
        case .v2:
            return "v2"
        }
    }

    private func stringField(_ key: String, from record: CKRecord) throws -> String {
        guard let value = record[key] as? String else {
            throw CloudKitRecordCodecError.missingField(key)
        }
        return value
    }

    private func uint32Field(_ key: String, from record: CKRecord) throws -> UInt32 {
        guard let value = record[key] as? NSNumber else {
            throw CloudKitRecordCodecError.missingField(key)
        }
        return value.uint32Value
    }

    private func dataField(_ key: String, from record: CKRecord) throws -> Data {
        guard let data = try optionalDataField(key, from: record) else {
            throw CloudKitRecordCodecError.missingField(key)
        }
        return data
    }

    private func optionalDataField(_ key: String, from record: CKRecord) throws -> Data? {
        if let data = record[key] as? Data {
            return data
        }
        if let data = record[key] as? NSData {
            return Data(referencing: data)
        }
        if record[key] == nil {
            return nil
        }
        throw CloudKitRecordCodecError.invalidField(key)
    }

    private static func encodedComponent(_ value: String) -> String {
        let encoded = Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded.isEmpty ? "_" : encoded
    }
}
#endif
