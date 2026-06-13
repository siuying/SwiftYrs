#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrsCloudKit
import Testing

/// A deterministic handler double: supplies records from a seeded table and
/// records every event the engine delivers.
private actor RecordingHandler: CloudKitSyncEngineHandler {
    private var records: [CKRecord.ID: CKRecord] = [:]
    private(set) var events: [CloudKitSyncEvent] = []

    func provide(_ record: CKRecord) {
        records[record.recordID] = record
    }

    func recordToSave(_ recordID: CKRecord.ID) async -> CKRecord? {
        records[recordID]
    }

    func handleEvent(_ event: CloudKitSyncEvent) async {
        events.append(event)
    }

    var sentEvents: [(saved: [CKRecord], deleted: [CKRecord.ID], failed: [CloudKitSendFailure])] {
        events.compactMap {
            if case let .sentChanges(saved, deleted, failed) = $0 {
                return (saved, deleted, failed)
            }
            return nil
        }
    }

    var fetchedEvents: [(modified: [CKRecord], deleted: [CKRecord.ID])] {
        events.compactMap {
            if case let .fetchedChanges(modified, deleted) = $0 {
                return (modified, deleted)
            }
            return nil
        }
    }

    var stateUpdates: [Data] {
        events.compactMap { if case let .stateUpdate(data) = $0 { return data }; return nil }
    }

    var accountChanges: [CloudKitAccountChange] {
        events.compactMap { if case let .accountChange(change) = $0 { return change }; return nil }
    }
}

private func record(_ name: String, value: String = "v") -> CKRecord {
    let id = CKRecord.ID(recordName: name, zoneID: CKRecordZone.ID(zoneName: "z"))
    let record = CKRecord(recordType: "T", recordID: id)
    record["field"] = value as NSString
    return record
}

@Test
func mockSavesEnqueuedRecordsAndReportsThem() async throws {
    let engine = MockCloudKitSyncEngine()
    let handler = RecordingHandler()
    await engine.setHandler(handler)

    let r = record("incremental.1")
    await handler.provide(r)
    await engine.enqueueSave(r.recordID)
    try await engine.sendChanges()

    let sent = await handler.sentEvents
    #expect(sent.count == 1)
    #expect(sent[0].saved.map(\.recordID) == [r.recordID])
    #expect(await engine.serverRecord(for: r.recordID)?.recordID == r.recordID)
    #expect(await engine.pendingSaveIDs.isEmpty)
    #expect(await handler.stateUpdates.count == 1)
}

@Test
func mockDeletesEnqueuedRecords() async throws {
    let engine = MockCloudKitSyncEngine()
    let handler = RecordingHandler()
    await engine.setHandler(handler)

    let r = record("incremental.1")
    await handler.provide(r)
    await engine.enqueueSave(r.recordID)
    try await engine.sendChanges()

    await engine.enqueueDelete(r.recordID)
    try await engine.sendChanges()

    let sent = await handler.sentEvents
    #expect(sent.last?.deleted == [r.recordID])
    #expect(await engine.serverRecord(for: r.recordID) == nil)
}

@Test
func mockDeliversFetchedRemoteChanges() async throws {
    let engine = MockCloudKitSyncEngine()
    let handler = RecordingHandler()
    await engine.setHandler(handler)

    let remote = record("incremental.2", value: "remote")
    await engine.simulateRemoteModification(remote)
    await engine.simulateRemoteDeletion(CKRecord.ID(recordName: "gone", zoneID: remote.recordID.zoneID))
    try await engine.fetchChanges()

    let fetched = await handler.fetchedEvents
    #expect(fetched.count == 1)
    #expect(fetched[0].modified.map(\.recordID) == [remote.recordID])
    #expect(fetched[0].deleted.map(\.recordName) == ["gone"])
}

@Test
func mockReportsConflictThenSucceedsOnRetry() async throws {
    let engine = MockCloudKitSyncEngine()
    let handler = RecordingHandler()
    await engine.setHandler(handler)

    let local = record("snapshot", value: "local")
    let serverSide = record("snapshot", value: "server")
    await handler.provide(local)
    await engine.seedConflict(for: local.recordID, serverRecord: serverSide)
    await engine.enqueueSave(local.recordID)

    // First send conflicts, handing back the server record; the change stays pending.
    try await engine.sendChanges()
    var sent = await handler.sentEvents
    #expect(sent.last?.failed.count == 1)
    #expect(sent.last?.failed.first?.error == .serverRecordChanged)
    #expect(sent.last?.failed.first?.serverRecord?["field"] as? String == "server")
    #expect(await engine.pendingSaveIDs == [local.recordID])

    // After the provider merges and re-supplies, the retry saves cleanly.
    let merged = record("snapshot", value: "merged")
    await handler.provide(merged)
    try await engine.sendChanges()
    sent = await handler.sentEvents
    #expect(sent.last?.saved.first?["field"] as? String == "merged")
    #expect(await engine.pendingSaveIDs.isEmpty)
}

@Test
func mockDeliversAccountChanges() async throws {
    let engine = MockCloudKitSyncEngine()
    let handler = RecordingHandler()
    await engine.setHandler(handler)

    await engine.simulateAccountChange(.switchAccounts)
    #expect(await handler.accountChanges == [.switchAccounts])
}

@Test
func mockAdvancesSerializedStateEachFlush() async throws {
    let engine = MockCloudKitSyncEngine()
    let handler = RecordingHandler()
    await engine.setHandler(handler)

    try await engine.sendChanges()
    try await engine.fetchChanges()

    let updates = await handler.stateUpdates
    #expect(updates.count == 2)
    #expect(updates[0] != updates[1]) // state advanced
}
#endif
