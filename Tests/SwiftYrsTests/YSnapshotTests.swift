import Foundation
import Testing
import SwiftYrs

@Test
func deletedItemRemainsReadableThroughSnapshotWhenGarbageCollectionIsSkipped() throws {
    let doc = YDoc(options: YDoc.Options(skipGC: true))
    #expect(doc.options.skipGC)
    let text = try doc.text(named: "body")

    let snapshot = try doc.write { transaction in
        try transaction.insert("before after", into: text, at: 0)
        return try transaction.snapshot()
    }

    try doc.write { transaction in
        try transaction.remove(from: text, at: 0, length: 7)
    }

    let restored = YDoc(options: YDoc.Options(skipGC: true))
    let restoredText = try restored.text(named: "body")
    try restored.apply(try doc.encodeStateFromSnapshotV1(snapshot))

    try restored.read { transaction in
        try #expect(transaction.string(from: restoredText) == "before after")
    }
}

@Test
func snapshotEncodingAndStateFromSnapshotInteroperateWithYjs() throws {
    let fixture = try YjsSnapshotFixture.load()
    let snapshot = try YSnapshot.decode(fixture.snapshot)
    #expect(snapshot.encode() == fixture.snapshot)

    let snapshotSource = YDoc(options: YDoc.Options(skipGC: true))
    try snapshotSource.apply(.v1(fixture.historicalUpdateV1))
    let swiftSnapshot = try snapshotSource.read { transaction in
        try transaction.snapshot()
    }
    #expect(swiftSnapshot.encode() == fixture.snapshot)

    let current = YDoc(options: YDoc.Options(skipGC: true))
    let currentText = try current.text(named: "body")
    try current.apply(.v1(fixture.currentUpdateV1))
    try current.read { transaction in
        try #expect(transaction.string(from: currentText) == "later after")
    }

    let historicalV1 = try current.encodeStateFromSnapshotV1(snapshot)
    let historicalV2 = try current.encodeStateFromSnapshotV2(snapshot)
    #expect(!historicalV1.data.isEmpty)
    #expect(!historicalV2.data.isEmpty)

    let restored = YDoc(options: YDoc.Options(skipGC: true))
    let restoredText = try restored.text(named: "body")
    try restored.apply(historicalV1)
    try restored.read { transaction in
        try #expect(transaction.string(from: restoredText) == "before after")
    }

    let restoredFromV2 = YDoc(options: YDoc.Options(skipGC: true))
    let restoredFromV2Text = try restoredFromV2.text(named: "body")
    try restoredFromV2.apply(historicalV2)
    try restoredFromV2.read { transaction in
        try #expect(transaction.string(from: restoredFromV2Text) == "before after")
    }

    let restoredFromYjs = YDoc(options: YDoc.Options(skipGC: true))
    let restoredFromYjsText = try restoredFromYjs.text(named: "body")
    try restoredFromYjs.apply(.v1(fixture.historicalUpdateV1))
    try restoredFromYjs.read { transaction in
        try #expect(transaction.string(from: restoredFromYjsText) == "before after")
    }

    let restoredFromYjsV2 = YDoc(options: YDoc.Options(skipGC: true))
    let restoredFromYjsV2Text = try restoredFromYjsV2.text(named: "body")
    try restoredFromYjsV2.apply(.v2(fixture.historicalUpdateV2))
    try restoredFromYjsV2.read { transaction in
        try #expect(transaction.string(from: restoredFromYjsV2Text) == "before after")
    }

    let currentFromV2 = YDoc(options: YDoc.Options(skipGC: true))
    let currentFromV2Text = try currentFromV2.text(named: "body")
    try currentFromV2.apply(.v2(fixture.currentUpdateV2))
    try currentFromV2.read { transaction in
        try #expect(transaction.string(from: currentFromV2Text) == "later after")
    }
}

@Test
func snapshotEncodingRequiresGarbageCollectionToBeSkipped() throws {
    let doc = YDoc()
    let text = try doc.text(named: "body")
    let snapshot = try doc.write { transaction in
        try transaction.insert("history", into: text, at: 0)
        return try transaction.snapshot()
    }

    #expect(throws: YError.garbageCollectionEnabled) {
        try doc.encodeStateFromSnapshotV1(snapshot)
    }
    #expect(throws: YError.garbageCollectionEnabled) {
        try doc.encodeStateFromSnapshotV2(snapshot)
    }
}

@Test
func malformedSnapshotIsRejectedByStateFromSnapshotEncoders() throws {
    let doc = YDoc(options: YDoc.Options(skipGC: true))
    let malformed = YSnapshot(Data([0xff]))

    #expect(throws: YError.decodeFailure) {
        try doc.encodeStateFromSnapshotV1(malformed)
    }
    #expect(throws: YError.decodeFailure) {
        try doc.encodeStateFromSnapshotV2(malformed)
    }
}

@Test
func defaultDocumentAndClientIDOptionsKeepGarbageCollectionEnabled() {
    #expect(YDoc().options.skipGC == false)
    #expect(YDoc(clientID: 42).options.skipGC == false)
    #expect(YDoc(clientID: 42, options: .init(skipGC: true)).options.skipGC)
}

@Test
func subdocumentCanBeCreatedWithGarbageCollectionSkipped() throws {
    let parent = YDoc()
    let map = try parent.map(named: "pages")
    let reference = try parent.write { transaction in
        try transaction.setNewSubdoc(
            forKey: "page",
            in: map,
            options: .init(skipGC: true)
        )
    }
    let subdoc = try parent.read { transaction in
        try transaction.subdocDoc(forKey: "page", in: map)
    }

    let referenceGUID = reference.guid
    let subdocGUID = try subdoc.guid
    #expect(referenceGUID == subdocGUID)
    #expect(subdoc.options.skipGC)
}

@Test
func callerGuidSubdocumentCanBeCreatedWithGarbageCollectionSkipped() throws {
    let parent = YDoc()
    let map = try parent.map(named: "pages")
    let guid = "018f0f50-7b5b-7d6d-9f51-9a54e3dc6c2a"
    let reference = try parent.write { transaction in
        try transaction.setNewSubdoc(
            guid: guid,
            forKey: "page",
            in: map,
            options: .init(skipGC: true)
        )
    }

    let subdoc = try parent.read { transaction in
        try transaction.subdocDoc(guid: guid)
    }
    #expect(reference.guid == guid)
    #expect(subdoc.options.skipGC)
}

@Test
func subdocumentGarbageCollectionSettingSurvivesReplication() throws {
    let source = YDoc()
    let sourceMap = try source.map(named: "pages")
    try source.write { transaction in
        _ = try transaction.setNewSubdoc(
            forKey: "page",
            in: sourceMap,
            options: .init(skipGC: true)
        )
    }

    let destination = YDoc()
    try destination.apply(try source.encodeStateAsUpdateV1())
    let destinationMap = try destination.map(named: "pages")
    let destinationPage = try destination.read { transaction in
        try transaction.subdocDoc(forKey: "page", in: destinationMap)
    }
    #expect(destinationPage.options.skipGC)
}

@Test
func invalidSnapshotEncodingThrowsDecodeFailure() {
    #expect(throws: YError.decodeFailure) {
        try YSnapshot.decode(Data([0xff]))
    }
}

private struct YjsSnapshotFixture: Decodable {
    let snapshot: Data
    let currentUpdateV1: Data
    let currentUpdateV2: Data
    let historicalUpdateV1: Data
    let historicalUpdateV2: Data

    static func load() throws -> YjsSnapshotFixture {
        try loadFixture("snapshot-document")
    }
}
