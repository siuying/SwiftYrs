#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import Testing

@Test
func incrementalRecordRoundTripsInlineUpdate() throws {
    let codec = CloudKitRecordCodec(assetDirectory: try temporaryDirectory(), inlineBytesLimit: 16)
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
    let codec = CloudKitRecordCodec(assetDirectory: try temporaryDirectory(), inlineBytesLimit: 2)
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
    let codec = CloudKitRecordCodec(assetDirectory: try temporaryDirectory())
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
func recordNamesAndZonesAreDerivedFromDocumentName() {
    let codec = CloudKitRecordCodec(assetDirectory: FileManager.default.temporaryDirectory)

    let firstZone = codec.zoneID(forDocumentName: "folder/doc #1")
    let sameZone = codec.zoneID(forDocumentName: "folder/doc #1")
    let otherZone = codec.zoneID(forDocumentName: "folder/doc #2")

    #expect(firstZone == sameZone)
    #expect(firstZone != otherZone)
    #expect(firstZone.zoneName.hasPrefix("swiftyrs."))

    let incrementalID = codec.incrementalRecordID(
        documentName: "folder/doc #1",
        clientID: 42,
        fromClock: 3,
        toClock: 9
    )
    #expect(incrementalID.zoneID == firstZone)
    #expect(incrementalID.recordName == "incremental.42.3.9")

    let snapshotID = codec.snapshotRecordID(documentName: "folder/doc #1")
    #expect(snapshotID.zoneID == firstZone)
    #expect(snapshotID.recordName == "snapshot")
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftYrsCloudKitRecordTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
#endif
