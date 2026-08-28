#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs

public enum CloudKitRecordCodecError: Error, Equatable {
    case missingField(String)
    case invalidField(String)
    case unsupportedUpdateEncoding(String)
    case missingAssetFile(String)
    /// A record name that does not match either document-scoped shape. Routing
    /// fails into the error stream rather than guessing an owner (ADR-0025).
    case malformedRecordName(String)
    /// A document name whose encoded form would overrun CloudKit's record-name
    /// length limit. See ``CloudKitRecordCodec/maximumDocumentNameBytes``.
    case documentNameTooLong(String)
    /// A zone name whose encoded form would overrun CloudKit's zone-name length
    /// limit. See ``CloudKitRecordCodec/maximumZoneNameBytes``.
    case zoneNameTooLong(String)
    /// The document encoded in the record name disagrees with the record's
    /// `documentName` field, so the update is not applied to either document.
    case documentNameMismatch(recordName: String, field: String)
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

/// Translates between `YUpdate` payloads and the `CKRecord`s of one store's
/// zone.
///
/// Every document of the store lives in the single zone named at construction
/// (ADR-0025), so record *names* — not zones — carry document identity:
/// `doc.<enc(documentName)>.incremental.<clientID>.<from>.<to>` and
/// `doc.<enc(documentName)>.snapshot`. A deleted-record callback delivers only
/// a `CKRecord.ID`, so ``documentName(fromRecordName:)`` is the store's routing
/// key; the `documentName` field is kept only to cross-check it on decode.
public struct CloudKitRecordCodec: Sendable {
    public static let defaultInlineBytesLimit = 900_000

    /// The caller's name for this store's zone (e.g. a vault UUID), before
    /// encoding into ``zoneID``.
    public let zoneName: String
    public let assetDirectory: URL
    public let inlineBytesLimit: Int

    /// The one zone holding every document of this store.
    public let zoneID: CKRecordZone.ID

    /// - Throws: ``CloudKitRecordCodecError/zoneNameTooLong(_:)`` if `zoneName`
    ///   exceeds ``maximumZoneNameBytes`` in UTF-8. CloudKit raises an
    ///   Objective-C exception for an over-long zone name, so this is checked
    ///   before the `CKRecordZone.ID` is built.
    public init(
        zoneName: String,
        assetDirectory: URL,
        inlineBytesLimit: Int = Self.defaultInlineBytesLimit
    ) throws {
        guard zoneName.utf8.count <= Self.maximumZoneNameBytes else {
            throw CloudKitRecordCodecError.zoneNameTooLong(zoneName)
        }
        self.zoneName = zoneName
        self.assetDirectory = assetDirectory
        self.inlineBytesLimit = inlineBytesLimit
        self.zoneID = CKRecordZone.ID(zoneName: "swiftyrs.\(Self.encodedComponent(zoneName))")
    }

    /// Rejects a document name that cannot fit in a record name. Callers check
    /// this once, when a provider starts, so the failure surfaces at setup
    /// rather than at the first flush.
    ///
    /// - Throws: ``CloudKitRecordCodecError/documentNameTooLong(_:)``.
    public func validate(documentName: String) throws {
        guard documentName.utf8.count <= Self.maximumDocumentNameBytes else {
            throw CloudKitRecordCodecError.documentNameTooLong(documentName)
        }
    }

    public func incrementalRecordID(
        documentName: String,
        clientID: UInt64,
        fromClock: UInt32,
        toClock: UInt32
    ) throws -> CKRecord.ID {
        try validate(documentName: documentName)
        return recordID(
            "\(Self.documentPrefix(documentName)).\(Self.incrementalKind).\(clientID).\(fromClock).\(toClock)"
        )
    }

    public func snapshotRecordID(documentName: String) throws -> CKRecord.ID {
        try validate(documentName: documentName)
        return recordID("\(Self.documentPrefix(documentName)).\(Self.snapshotKind)")
    }

    /// The document a record belongs to, recovered from its name alone — the
    /// only identity a deleted-record callback carries.
    ///
    /// - Throws: ``CloudKitRecordCodecError/malformedRecordName(_:)`` for a name
    ///   that is not one of the two document-scoped shapes. Callers surface the
    ///   error; they never fall back to another document.
    public func documentName(fromRecordName recordName: String) throws -> String {
        let components = recordName.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3, components[0] == Self.documentTag else {
            throw CloudKitRecordCodecError.malformedRecordName(recordName)
        }
        switch components[2] {
        case Self.snapshotKind:
            guard components.count == 3 else {
                throw CloudKitRecordCodecError.malformedRecordName(recordName)
            }
        case Self.incrementalKind:
            guard components.count == 6,
                  UInt64(components[3]) != nil,
                  UInt32(components[4]) != nil,
                  UInt32(components[5]) != nil
            else {
                throw CloudKitRecordCodecError.malformedRecordName(recordName)
            }
        default:
            throw CloudKitRecordCodecError.malformedRecordName(recordName)
        }
        guard let documentName = Self.decodedComponent(String(components[1])) else {
            throw CloudKitRecordCodecError.malformedRecordName(recordName)
        }
        return documentName
    }

    private func recordID(_ recordName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }

    /// Rejects a record whose name and `documentName` field disagree, so a
    /// forged or corrupted name cannot land an update on another document.
    private func verifiedDocumentName(of record: CKRecord) throws -> String {
        let fromName = try documentName(fromRecordName: record.recordID.recordName)
        let fromField = try stringField(CloudKitRecordField.documentName, from: record)
        guard fromName == fromField else {
            throw CloudKitRecordCodecError.documentNameMismatch(
                recordName: fromName,
                field: fromField
            )
        }
        return fromName
    }

    public func encodeIncremental(_ payload: CloudKitIncrementalRecordPayload) throws -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitRecordType.incremental,
            recordID: try incrementalRecordID(
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
        let documentName = try verifiedDocumentName(of: record)
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
            recordID: try snapshotRecordID(documentName: payload.documentName)
        )
        record[CloudKitRecordField.documentName] = payload.documentName as NSString
        record[CloudKitRecordField.updateEncoding] = encodingName(payload.update.encoding) as NSString
        record[CloudKitRecordField.snapshotUpdate] = try asset(for: payload.update.data)
        record[CloudKitRecordField.stateVector] = payload.stateVector.data as NSData
        return record
    }

    public func decodeSnapshot(_ record: CKRecord) throws -> CloudKitSnapshotRecordPayload {
        let documentName = try verifiedDocumentName(of: record)
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

    private static let documentTag = "doc"
    private static let incrementalKind = "incremental"
    private static let snapshotKind = "snapshot"

    /// CloudKit's cap on a record name and a zone name.
    private static let maximumCloudKitNameLength = 255

    /// Fixed characters around the encoded document component of the longest
    /// record name: `doc.` + `.incremental.` + a max `UInt64` client ID + two
    /// max `UInt32` clocks with their separators.
    private static let longestRecordNameOverhead =
        "\(documentTag).".count + ".\(incrementalKind).".count
            + String(UInt64.max).count + 1 + String(UInt32.max).count + 1 + String(UInt32.max).count

    /// The longest document name, in UTF-8 bytes, whose encoding still fits a
    /// record name. The bound is the same for snapshot and incremental records
    /// so a name never works for one and fails for the other.
    public static let maximumDocumentNameBytes =
        encodableBytes(within: maximumCloudKitNameLength - longestRecordNameOverhead)

    /// The longest zone name, in UTF-8 bytes, whose encoding still fits a zone
    /// ID.
    public static let maximumZoneNameBytes =
        encodableBytes(within: maximumCloudKitNameLength - "swiftyrs.".count)

    /// How many raw bytes survive unpadded base64 within `characters`.
    private static func encodableBytes(within characters: Int) -> Int {
        characters * 3 / 4
    }

    private static func documentPrefix(_ documentName: String) -> String {
        "\(documentTag).\(encodedComponent(documentName))"
    }

    /// URL-safe, unpadded base64. It never contains `.`, which is what lets a
    /// record name be split on `.` unambiguously.
    private static func encodedComponent(_ value: String) -> String {
        let encoded = Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded.isEmpty ? emptyComponent : encoded
    }

    /// The sentinel for an empty value. Base64 never produces a single
    /// character, so it cannot collide with a real encoding.
    private static let emptyComponent = "_"

    private static func decodedComponent(_ component: String) -> String? {
        if component == emptyComponent { return "" }
        var base64 = component
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
