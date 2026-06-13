#if canImport(CloudKit)
import CloudKit
import Foundation

/// A deterministic, in-memory ``CloudKitSyncEngineAdapter`` for driving the
/// provider in tests with no live iCloud account (PRD story 33). It models one
/// CloudKit zone as a record dictionary, queues "other device" changes for the
/// next fetch, and can seed `serverRecordChanged` conflicts and account events.
///
/// Behavior is fully ordered and side-effect-free beyond its own state, so tests
/// step it explicitly: enqueue → `sendChanges()`/`fetchChanges()` → assert the
/// events the handler received and the records the simulated server now holds.
public actor MockCloudKitSyncEngine: CloudKitSyncEngineAdapter {
    private weak var handler: CloudKitSyncEngineHandler?

    /// The simulated server zone contents, keyed by record ID.
    private var server: [CKRecord.ID: CKRecord] = [:]

    private var pendingSaves: [CKRecord.ID] = []
    private var pendingDeletes: [CKRecord.ID] = []

    /// Changes from other devices awaiting the next `fetchChanges()`.
    private var inboundModified: [CKRecord] = []
    private var inboundDeleted: [CKRecord.ID] = []

    /// Record IDs whose next save fails with `serverRecordChanged`, paired with
    /// the server record handed back so the provider can merge and retry.
    private var seededConflicts: [CKRecord.ID: CKRecord] = [:]

    /// Monotonic counter encoded as the engine's serialized state, so tests can
    /// observe that state advanced after each send/fetch.
    private var stateGeneration = 0

    public init() {}

    // MARK: CloudKitSyncEngineAdapter

    /// The state serialization the engine was restored from, if any. A nil
    /// value means a cold start (full re-fetch in the real engine).
    public private(set) var restoredState: Data?

    public func setHandler(_ handler: CloudKitSyncEngineHandler) {
        self.handler = handler
    }

    public func loadState(_ data: Data) {
        restoredState = data
    }

    public func enqueueSave(_ recordID: CKRecord.ID) {
        if !pendingSaves.contains(recordID) {
            pendingSaves.append(recordID)
        }
        pendingDeletes.removeAll { $0 == recordID }
    }

    public func enqueueDelete(_ recordID: CKRecord.ID) {
        if !pendingDeletes.contains(recordID) {
            pendingDeletes.append(recordID)
        }
        pendingSaves.removeAll { $0 == recordID }
    }

    public func sendChanges() async throws {
        guard let handler else { return }

        var saved: [CKRecord] = []
        var failed: [CloudKitSendFailure] = []
        var stillPending: [CKRecord.ID] = []

        for recordID in pendingSaves {
            if let serverRecord = seededConflicts[recordID] {
                // Conflict once: hand back the server record and keep the change
                // pending so a post-merge retry can succeed.
                seededConflicts[recordID] = nil
                stillPending.append(recordID)
                failed.append(
                    CloudKitSendFailure(
                        recordID: recordID,
                        serverRecord: serverRecord,
                        error: .serverRecordChanged
                    )
                )
                continue
            }
            guard let record = await handler.recordToSave(recordID) else { continue }
            server[recordID] = record
            saved.append(record)
        }
        pendingSaves = stillPending

        var deleted: [CKRecord.ID] = []
        for recordID in pendingDeletes {
            server[recordID] = nil
            deleted.append(recordID)
        }
        pendingDeletes = []

        if !saved.isEmpty || !deleted.isEmpty || !failed.isEmpty {
            await handler.handleEvent(.sentChanges(saved: saved, deleted: deleted, failed: failed))
        }
        await emitStateUpdate(to: handler)
    }

    public func fetchChanges() async throws {
        guard let handler else { return }

        let modified = inboundModified
        let deleted = inboundDeleted
        inboundModified = []
        inboundDeleted = []

        if !modified.isEmpty || !deleted.isEmpty {
            await handler.handleEvent(.fetchedChanges(modified: modified, deleted: deleted))
        }
        await emitStateUpdate(to: handler)
    }

    public func deleteZone(_ zoneID: CKRecordZone.ID) async {
        for recordID in server.keys where recordID.zoneID == zoneID {
            server[recordID] = nil
        }
        inboundModified.removeAll { $0.recordID.zoneID == zoneID }
        inboundDeleted.removeAll { $0.zoneID == zoneID }
        pendingSaves.removeAll { $0.zoneID == zoneID }
        pendingDeletes.removeAll { $0.zoneID == zoneID }
    }

    // MARK: Test-driving surface

    /// Simulate another device saving `record`: it lands in the server zone and
    /// is delivered on the next `fetchChanges()`.
    public func simulateRemoteModification(_ record: CKRecord) {
        server[record.recordID] = record
        inboundModified.removeAll { $0.recordID == record.recordID }
        inboundModified.append(record)
    }

    /// Simulate another device deleting `recordID`.
    public func simulateRemoteDeletion(_ recordID: CKRecord.ID) {
        server[recordID] = nil
        inboundDeleted.append(recordID)
    }

    /// Make the next save of `recordID` fail with `serverRecordChanged`, handing
    /// `serverRecord` back to the provider's merge path.
    public func seedConflict(for recordID: CKRecord.ID, serverRecord: CKRecord) {
        server[recordID] = serverRecord
        seededConflicts[recordID] = serverRecord
    }

    /// Deliver an account-change event to the handler.
    public func simulateAccountChange(_ change: CloudKitAccountChange) async {
        await handler?.handleEvent(.accountChange(change))
    }

    /// The record the simulated server currently holds for `recordID`.
    public func serverRecord(for recordID: CKRecord.ID) -> CKRecord? {
        server[recordID]
    }

    /// Every record ID the simulated server currently holds.
    public var serverRecordIDs: [CKRecord.ID] {
        Array(server.keys)
    }

    public var pendingSaveIDs: [CKRecord.ID] {
        pendingSaves
    }

    private func emitStateUpdate(to handler: CloudKitSyncEngineHandler) async {
        stateGeneration += 1
        await handler.handleEvent(.stateUpdate(Data("state-\(stateGeneration)".utf8)))
    }
}
#endif
