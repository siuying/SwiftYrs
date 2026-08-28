#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import Testing

@Test
func incrementalRecordRoundTripsInlineUpdate() throws {
    let codec = try CloudKitRecordCodec(
        zoneName: "vault",
        assetDirectory: try temporaryDirectory(),
        inlineBytesLimit: 16
    )
    let payload = CloudKitIncrementalRecordPayload(
        documentName: "notes/today",
        clientID: 42,
        fromClock: 0,
        toClock: 3,
        update: .v1(Data([1, 2, 3]))
    )

    let record = try codec.encodeIncremental(payload)
    #expect(record[CloudKitRecordField.inlineUpdate] as? Data == Data([1, 2, 3]))
    #expect(record[CloudKitRecordField.assetUpdate] == nil)

    #expect(try codec.decodeIncremental(record) == payload)
}

@Test
func incrementalRecordFallsBackToAssetWhenUpdateExceedsInlineLimit() throws {
    let codec = try CloudKitRecordCodec(
        zoneName: "vault",
        assetDirectory: try temporaryDirectory(),
        inlineBytesLimit: 2
    )
    let payload = CloudKitIncrementalRecordPayload(
        documentName: "asset-doc",
        clientID: 7,
        fromClock: 2,
        toClock: 5,
        update: .v1(Data([1, 2, 3]))
    )

    let record = try codec.encodeIncremental(payload)
    #expect(record[CloudKitRecordField.inlineUpdate] == nil)
    #expect(record[CloudKitRecordField.assetUpdate] is CKAsset)

    #expect(try codec.decodeIncremental(record) == payload)
}

@Test
func snapshotRecordRoundTripsAssetUpdateAndStateVector() throws {
    let codec = try CloudKitRecordCodec(zoneName: "vault", assetDirectory: try temporaryDirectory())
    let payload = CloudKitSnapshotRecordPayload(
        documentName: "snap-doc",
        update: .v1(Data([9, 8, 7])),
        stateVector: YStateVector(Data([1, 1, 2, 3]))
    )

    let record = try codec.encodeSnapshot(payload)
    #expect(record[CloudKitRecordField.snapshotUpdate] is CKAsset)
    #expect(record[CloudKitRecordField.stateVector] as? Data == Data([1, 1, 2, 3]))

    #expect(try codec.decodeSnapshot(record) == payload)
}

@Test
func everyDocumentOfAStoreLivesInTheOneZoneNamedAtConstruction() throws {
    let codec = try CloudKitRecordCodec(zoneName: "vault-1", assetDirectory: FileManager.default.temporaryDirectory)

    let incrementalID = try codec.incrementalRecordID(
        documentName: "folder/doc #1",
        clientID: 42,
        fromClock: 3,
        toClock: 9
    )
    let otherDocumentID = try codec.snapshotRecordID(documentName: "folder/doc #2")

    #expect(codec.zoneID.zoneName.hasPrefix("swiftyrs."))
    #expect(incrementalID.zoneID == codec.zoneID)
    #expect(otherDocumentID.zoneID == codec.zoneID)
}

@Test
func storesWithDifferentZoneNamesUseDifferentZones() throws {
    let assets = FileManager.default.temporaryDirectory
    let first = try CloudKitRecordCodec(zoneName: "vault-1", assetDirectory: assets)
    let second = try CloudKitRecordCodec(zoneName: "vault-2", assetDirectory: assets)
    let same = try CloudKitRecordCodec(zoneName: "vault-1", assetDirectory: assets)

    #expect(first.zoneID != second.zoneID)
    #expect(first.zoneID == same.zoneID)
}

@Test
func recordNamesCarryTheDocumentComponent() throws {
    let codec = try CloudKitRecordCodec(zoneName: "vault", assetDirectory: FileManager.default.temporaryDirectory)
    let encoded = "Zm9sZGVyL2RvYyAjMQ" // URL-safe base64 of "folder/doc #1", unpadded

    let incrementalID = try codec.incrementalRecordID(
        documentName: "folder/doc #1",
        clientID: 42,
        fromClock: 3,
        toClock: 9
    )
    #expect(incrementalID.recordName == "doc.\(encoded).incremental.42.3.9")

    let snapshotID = try codec.snapshotRecordID(documentName: "folder/doc #1")
    #expect(snapshotID.recordName == "doc.\(encoded).snapshot")
}

@Test(arguments: [
    "folder/doc #1",
    "",
    "a.b.c.incremental.1.2.3",
    "🌍 unicode ünïcödé",
    String(repeating: "a", count: CloudKitRecordCodec.maximumDocumentNameBytes),
])
func documentNameRoundTripsThroughRecordNames(documentName: String) throws {
    let codec = try CloudKitRecordCodec(zoneName: "vault", assetDirectory: FileManager.default.temporaryDirectory)

    let incrementalID = try codec.incrementalRecordID(
        documentName: documentName,
        clientID: .max,
        fromClock: 0,
        toClock: .max
    )
    let snapshotID = try codec.snapshotRecordID(documentName: documentName)

    // Every record name a document can produce fits CloudKit's 255-char cap.
    #expect(incrementalID.recordName.count <= 255)
    #expect(snapshotID.recordName.count <= 255)

    #expect(try codec.documentName(fromRecordName: incrementalID.recordName) == documentName)
    #expect(try codec.documentName(fromRecordName: snapshotID.recordName) == documentName)
}

@Test(arguments: [
    "",
    "snapshot",
    "incremental.42.3.9",
    "doc",
    "doc.",
    "doc.Zm9v",
    "doc.Zm9v.unknown",
    "doc.Zm9v.snapshot.extra",
    "doc.Zm9v.incremental.42.3",
    "doc.Zm9v.incremental.42.3.9.10",
    "doc.Zm9v.incremental.notanumber.3.9",
    "doc.Zm9v.incremental.42.-1.9",
    "doc.!!!not base64!!!.snapshot",
    "page.Zm9v.snapshot",
])
func malformedRecordNamesThrowRatherThanRoutingToAnotherDocument(recordName: String) throws {
    let codec = try CloudKitRecordCodec(zoneName: "vault", assetDirectory: FileManager.default.temporaryDirectory)

    #expect(throws: CloudKitRecordCodecError.malformedRecordName(recordName)) {
        try codec.documentName(fromRecordName: recordName)
    }
}

@Test
func namesTooLongForCloudKitAreRejectedBeforeTheyReachIt() throws {
    let assets = FileManager.default.temporaryDirectory
    let tooLongDocument = String(repeating: "a", count: CloudKitRecordCodec.maximumDocumentNameBytes + 1)
    let tooLongZone = String(repeating: "a", count: CloudKitRecordCodec.maximumZoneNameBytes + 1)

    #expect(throws: CloudKitRecordCodecError.zoneNameTooLong(tooLongZone)) {
        try CloudKitRecordCodec(zoneName: tooLongZone, assetDirectory: assets)
    }

    let codec = try CloudKitRecordCodec(zoneName: "vault", assetDirectory: assets)
    #expect(throws: CloudKitRecordCodecError.documentNameTooLong(tooLongDocument)) {
        try codec.snapshotRecordID(documentName: tooLongDocument)
    }
    #expect(throws: CloudKitRecordCodecError.documentNameTooLong(tooLongDocument)) {
        try codec.incrementalRecordID(documentName: tooLongDocument, clientID: 1, fromClock: 0, toClock: 1)
    }
}

@Test
func decodingFailsWhenTheRecordNameAndDocumentFieldDisagree() throws {
    let codec = try CloudKitRecordCodec(
        zoneName: "vault",
        assetDirectory: try temporaryDirectory(),
        inlineBytesLimit: 16
    )
    let record = try codec.encodeIncremental(
        CloudKitIncrementalRecordPayload(
            documentName: "a",
            clientID: 42,
            fromClock: 0,
            toClock: 3,
            update: .v1(Data([1, 2, 3]))
        )
    )
    record[CloudKitRecordField.documentName] = "b" as NSString

    #expect(throws: CloudKitRecordCodecError.documentNameMismatch(recordName: "a", field: "b")) {
        try codec.decodeIncremental(record)
    }
}

@Test
func decodingASnapshotFailsWhenTheRecordNameAndDocumentFieldDisagree() throws {
    let codec = try CloudKitRecordCodec(zoneName: "vault", assetDirectory: try temporaryDirectory())
    let record = try codec.encodeSnapshot(
        CloudKitSnapshotRecordPayload(
            documentName: "a",
            update: .v1(Data([9, 8, 7])),
            stateVector: YStateVector(Data([1]))
        )
    )
    record[CloudKitRecordField.documentName] = "b" as NSString

    #expect(throws: CloudKitRecordCodecError.documentNameMismatch(recordName: "a", field: "b")) {
        try codec.decodeSnapshot(record)
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftYrsCloudKitRecordTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
#endif
