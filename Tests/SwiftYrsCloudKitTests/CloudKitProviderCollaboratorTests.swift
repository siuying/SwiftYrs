#if canImport(CloudKit)
import CloudKit
import Foundation
@testable import SwiftYrsCloudKit
import Testing

@Test
func drainSetManagerOwnsDrainSetPersistence() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftyrs-drain-set-\(UUID().uuidString)")
    let metadata = FileCloudKitMetadataStore(directory: directory)
    var manager = DrainSetManager(metadataStore: metadata, documentName: "doc")

    #expect(manager.load() == [:])

    manager.replace(with: [11: 0, 22: 4])
    var reloaded = DrainSetManager(metadataStore: metadata, documentName: "doc")
    #expect(reloaded.load() == [11: 0, 22: 4])

    reloaded.update(clientID: 22, marker: 9)
    reloaded.retire(clientID: 11)
    var updated = DrainSetManager(metadataStore: metadata, documentName: "doc")
    #expect(updated.load() == [22: 9])

    updated.clear()
    var cleared = DrainSetManager(metadataStore: metadata, documentName: "doc")
    #expect(cleared.load() == [:])
}

@Test
func recordQueueOwnsPendingRecordLifecycle() {
    let zoneID = CKRecordZone.ID(zoneName: "zone")
    let firstID = CKRecord.ID(recordName: "one", zoneID: zoneID)
    let secondID = CKRecord.ID(recordName: "two", zoneID: zoneID)
    let first = CKRecord(recordType: "Test", recordID: firstID)
    let second = CKRecord(recordType: "Test", recordID: secondID)
    let queue = RecordQueue()

    queue.enqueue(first)
    queue.enqueue(second)

    #expect(queue.record(toSave: firstID) === first)
    #expect(queue.record(toSave: secondID) === second)

    queue.remove(firstID)
    #expect(queue.record(toSave: firstID) == nil)
    #expect(queue.record(toSave: secondID) === second)

    queue.removeAll()
    #expect(queue.record(toSave: secondID) == nil)
}
#endif
