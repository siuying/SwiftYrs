#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs

final class SnapshotWriter: @unchecked Sendable {
    private let document: CloudKitDocumentKey
    private let doc: YDoc
    private let store: CloudKitSyncStore
    private let options: CloudKitProviderOptions
    private let recordQueue: RecordQueue

    private var knownIncrementals: [CKRecord.ID: IncrementalSummary] = [:]
    private var confirmedSnapshotStateVector: YStateVector?
    private var snapshotConflictServerRecord: CKRecord?

    private(set) var latestSnapshotStateVector: ClientClockMap?

    init(
        document: CloudKitDocumentKey,
        doc: YDoc,
        store: CloudKitSyncStore,
        options: CloudKitProviderOptions,
        recordQueue: RecordQueue
    ) {
        self.document = document
        self.doc = doc
        self.store = store
        self.options = options
        self.recordQueue = recordQueue
    }

    var incrementalSummaries: [IncrementalSummary] {
        Array(knownIncrementals.values)
    }

    func writeSnapshot(
        applyWithRetry: @Sendable (YUpdate) async throws -> Void,
        reportError: @Sendable (Error) -> Void
    ) async {
        var attempts = 0
        while attempts < options.maxSnapshotRetries {
            attempts += 1
            confirmedSnapshotStateVector = nil
            snapshotConflictServerRecord = nil
            do {
                let full = try await captureFullState()
                let record = try store.codec.encodeSnapshot(
                    CloudKitSnapshotRecordPayload(
                        documentName: document.name,
                        update: full.update,
                        stateVector: full.stateVector
                    )
                )
                recordQueue.enqueue(record)
                await store.enqueueSave(record.recordID)
                try await store.sendChanges()
            } catch {
                reportError(error)
                return
            }

            if let serverRecord = snapshotConflictServerRecord {
                snapshotConflictServerRecord = nil
                if let payload = try? store.codec.decodeSnapshot(serverRecord) {
                    try? await applyWithRetry(payload.update)
                }
                continue
            }
            if let stateVector = confirmedSnapshotStateVector {
                await gcSubsumed(confirmedStateVector: stateVector)
            }
            return
        }
    }

    func handleSavedSnapshot(_ record: CKRecord) -> Bool {
        guard record.recordType == CloudKitRecordType.snapshot else {
            return false
        }
        if let payload = try? store.codec.decodeSnapshot(record) {
            confirmedSnapshotStateVector = payload.stateVector
            latestSnapshotStateVector = try? ClientClockMap(decoding: payload.stateVector)
        }
        return true
    }

    func handleSnapshotFailure(_ failure: CloudKitSendFailure) -> Bool {
        guard failure.recordID == store.codec.snapshotRecordID(document),
              failure.error == .serverRecordChanged
        else {
            return false
        }
        snapshotConflictServerRecord = failure.serverRecord
        return true
    }

    func noteSnapshot(stateVector: YStateVector) {
        latestSnapshotStateVector = try? ClientClockMap(decoding: stateVector)
    }

    func trackIncremental(clientID: UInt64, fromClock: UInt32, toClock: UInt32, byteCount: Int) {
        let recordID = store.codec.incrementalRecordID(
            document,
            clientID: clientID,
            fromClock: fromClock,
            toClock: toClock
        )
        knownIncrementals[recordID] = IncrementalSummary(
            clientID: clientID,
            fromClock: fromClock,
            toClock: toClock,
            byteCount: byteCount
        )
    }

    func removeKnownIncremental(_ recordID: CKRecord.ID) {
        knownIncrementals[recordID] = nil
    }

    func removeAllKnownIncrementals() {
        knownIncrementals.removeAll()
        latestSnapshotStateVector = nil
        confirmedSnapshotStateVector = nil
        snapshotConflictServerRecord = nil
    }

    private func captureFullState() async throws -> (update: YUpdate, stateVector: YStateVector) {
        var attempts = 0
        while true {
            do {
                return (try doc.encodeStateAsUpdateV1(), try doc.stateVector())
            } catch YError.transactionConflict {
                attempts += 1
                guard attempts < options.maxTransactionRetries else {
                    throw CloudKitProviderError.transactionConflict
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func gcSubsumed(confirmedStateVector: YStateVector) async {
        guard let confirmed = try? ConfirmedSnapshot(confirmedSaved: confirmedStateVector) else { return }
        let subsumed = options.compaction.subsumedIncrementals(
            Array(knownIncrementals.values),
            by: confirmed
        )
        guard !subsumed.isEmpty else { return }
        for summary in subsumed {
            let recordID = store.codec.incrementalRecordID(
                document,
                clientID: summary.clientID,
                fromClock: summary.fromClock,
                toClock: summary.toClock
            )
            knownIncrementals[recordID] = nil
            await store.enqueueDelete(recordID)
        }
        try? await store.sendChanges()
    }
}
#endif
