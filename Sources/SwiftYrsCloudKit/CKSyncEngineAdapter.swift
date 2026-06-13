#if canImport(CloudKit)
import CloudKit
import Foundation

/// The concrete ``CloudKitSyncEngineAdapter`` backed by the real `CKSyncEngine`
/// over a private database (ADR-0023). It maps each seam operation to its
/// `CKSyncEngine` mechanism and translates `CKSyncEngine` events into the seam's
/// `CloudKitSyncEvent`s; the provider's correctness logic is proven against the
/// mock, so this layer is pure plumbing (no live-iCloud assertions).
///
/// The engine is created lazily on first use so the persisted state restored via
/// ``loadState(_:)`` is available at configuration time — losing it forces a
/// cold re-fetch, so the store persists every `stateUpdate`.
public actor CKSyncEngineAdapter: CloudKitSyncEngineAdapter {
    private let database: CKDatabase
    private weak var handler: CloudKitSyncEngineHandler?
    private var restoredState: CKSyncEngine.State.Serialization?
    private var engine: CKSyncEngine?
    private var requestedZones: Set<CKRecordZone.ID> = []

    public init(database: CKDatabase) {
        self.database = database
    }

    public init(containerIdentifier: String) {
        self.database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    public func setHandler(_ handler: CloudKitSyncEngineHandler) {
        self.handler = handler
    }

    public func loadState(_ data: Data) {
        restoredState = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    public func enqueueSave(_ recordID: CKRecord.ID) {
        let syncEngine = ensureEngine()
        ensureZone(recordID.zoneID, on: syncEngine)
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    public func enqueueDelete(_ recordID: CKRecord.ID) {
        ensureEngine().state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }

    public func sendChanges() async throws {
        try await ensureEngine().sendChanges()
    }

    public func fetchChanges() async throws {
        try await ensureEngine().fetchChanges()
    }

    public func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
        let syncEngine = ensureEngine()
        requestedZones.remove(zoneID)
        syncEngine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
        try await syncEngine.sendChanges()
    }

    // MARK: Engine lifecycle

    private func ensureEngine() -> CKSyncEngine {
        if let engine { return engine }
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: restoredState,
            delegate: self
        )
        configuration.automaticallySync = true
        let created = CKSyncEngine(configuration)
        engine = created
        return created
    }

    private func ensureZone(_ zoneID: CKRecordZone.ID, on syncEngine: CKSyncEngine) {
        guard !requestedZones.contains(zoneID) else { return }
        requestedZones.insert(zoneID)
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }
}

// MARK: - CKSyncEngineDelegate

extension CKSyncEngineAdapter: CKSyncEngineDelegate {
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let handler else { return }
        switch event {
        case let .stateUpdate(update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                await handler.handleEvent(.stateUpdate(data))
            }
        case let .accountChange(change):
            if let mapped = Self.accountChange(change.changeType) {
                await handler.handleEvent(.accountChange(mapped))
            }
        case let .fetchedRecordZoneChanges(changes):
            await handler.handleEvent(
                .fetchedChanges(
                    modified: changes.modifications.map(\.record),
                    deleted: changes.deletions.map(\.recordID)
                )
            )
        case let .sentRecordZoneChanges(sent):
            await handler.handleEvent(
                .sentChanges(
                    saved: sent.savedRecords,
                    deleted: sent.deletedRecordIDs,
                    failed: sent.failedRecordSaves.map(Self.sendFailure)
                )
            )
        default:
            // willFetch/willSend/didFetch/didSend/database-change events are not
            // consumed by the provider.
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            if case .saveRecord = $0 { return true }
            return false
        }
        guard !pending.isEmpty, let handler else { return nil }

        // The batch's record provider is synchronous, so resolve each record's
        // bytes up front from the (async) handler.
        var resolved: [CKRecord.ID: CKRecord] = [:]
        for change in pending {
            if case let .saveRecord(recordID) = change {
                resolved[recordID] = await handler.recordToSave(recordID)
            }
        }
        let records = resolved
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            records[recordID]
        }
    }

    private static func accountChange(
        _ changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) -> CloudKitAccountChange? {
        switch changeType {
        case .signIn:
            return .signIn
        case .signOut:
            return .signOut
        case .switchAccounts:
            return .switchAccounts
        @unknown default:
            return nil
        }
    }

    private static func sendFailure(
        _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave
    ) -> CloudKitSendFailure {
        let error = failure.error
        let mapped: CloudKitSendError
        switch error.code {
        case .serverRecordChanged:
            mapped = .serverRecordChanged
        case .zoneNotFound, .userDeletedZone:
            mapped = .zoneNotFound
        case .unknownItem:
            mapped = .unknownItem
        default:
            mapped = .other(error.localizedDescription)
        }
        return CloudKitSendFailure(
            recordID: failure.record.recordID,
            serverRecord: error.serverRecord,
            error: mapped
        )
    }
}
#endif
