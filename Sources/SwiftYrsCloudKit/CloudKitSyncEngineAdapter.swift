#if canImport(CloudKit)
import CloudKit
import Foundation

/// The iCloud account-state transitions the engine surfaces (ADR-0023). The
/// provider stops syncing and clears CloudKit-local state on a sign-out or
/// switch, and never auto-uploads the existing document to a new account.
public enum CloudKitAccountChange: Equatable, Sendable {
    case signIn
    case signOut
    case switchAccounts
}

/// Why a record failed to save. `serverRecordChanged` is the conflict the
/// snapshot's merge-on-conflict path resolves; the rest are surfaced as errors.
public enum CloudKitSendError: Equatable, Sendable {
    case serverRecordChanged
    case zoneNotFound
    case unknownItem
    case other(String?)
}

/// One failed record save. On a `serverRecordChanged` conflict, `serverRecord`
/// carries the server's current record so the provider can apply-and-retry.
public struct CloudKitSendFailure: Sendable {
    public let recordID: CKRecord.ID
    public let serverRecord: CKRecord?
    public let error: CloudKitSendError

    public init(recordID: CKRecord.ID, serverRecord: CKRecord?, error: CloudKitSendError) {
        self.recordID = recordID
        self.serverRecord = serverRecord
        self.error = error
    }
}

/// Events the engine delivers to its handler — a narrowing of `CKSyncEngine`'s
/// event stream to what the provider consumes.
public enum CloudKitSyncEvent: Sendable {
    /// The engine's serialized state to persist; losing it forces a cold
    /// re-fetch, so the provider writes it through its metadata store.
    case stateUpdate(Data)
    case accountChange(CloudKitAccountChange)
    /// Remote records fetched from CloudKit (modified and deleted).
    case fetchedChanges(modified: [CKRecord], deleted: [CKRecord.ID])
    /// The outcome of a send: records saved, records deleted, and failures.
    case sentChanges(saved: [CKRecord], deleted: [CKRecord.ID], failed: [CloudKitSendFailure])
}

/// The provider side of the seam. The engine asks it for record bytes at send
/// time — so payloads are computed lazily from the live doc, not buffered — and
/// pushes every event to it.
public protocol CloudKitSyncEngineHandler: AnyObject, Sendable {
    /// The current record for `recordID`, recomputed at send time, or `nil` if
    /// it is no longer relevant (e.g. superseded by a snapshot).
    func recordToSave(_ recordID: CKRecord.ID) async -> CKRecord?
    func handleEvent(_ event: CloudKitSyncEvent) async
}

/// The `CKSyncEngine` surface the provider depends on (ADR-0023). The real
/// adapter (issue #69) wraps `CKSyncEngine`; `MockCloudKitSyncEngine` drives the
/// same protocol deterministically so the whole provider is testable without a
/// live iCloud account. The currency is the record codec's `CKRecord` shapes.
public protocol CloudKitSyncEngineAdapter: Sendable {
    /// Wires the handler that supplies record bytes and receives events.
    func setHandler(_ handler: CloudKitSyncEngineHandler) async

    /// Restore the engine from a previously-persisted state serialization so a
    /// relaunch resumes from its change token instead of cold-fetching the whole
    /// document. Called once at startup when persisted state exists.
    func loadState(_ data: Data) async

    /// Enqueue a pending record save/delete. Bytes are supplied later via
    /// ``CloudKitSyncEngineHandler/recordToSave(_:)`` at send time.
    func enqueueSave(_ recordID: CKRecord.ID) async
    func enqueueDelete(_ recordID: CKRecord.ID) async

    /// Flush pending changes to CloudKit, delivering a `sentChanges` event.
    func sendChanges() async throws
    /// Pull remote changes, delivering a `fetchedChanges` event when any exist.
    func fetchChanges() async throws
}
#endif
