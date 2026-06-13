#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs

public struct CloudKitProviderOptions: Sendable {
    /// Quiet-period debounce before a flush (ADR-0023: ~30 s). Tests use a
    /// short value; production keeps the default.
    public let debounce: Duration
    /// Attempts to capture a diff before giving up on `transactionConflict`.
    public let maxTransactionRetries: Int
    /// Compaction/GC decisions (ADR-0023/0024).
    public let compaction: CompactionPolicy
    /// Per-attempt jitter in `0...1`, used to stagger the multi-device
    /// compaction herd. Defaults to a fresh random value each attempt.
    public let jitter: @Sendable () -> Double
    /// Attempts to write the snapshot before giving up on a conflict loop.
    public let maxSnapshotRetries: Int

    public init(
        debounce: Duration = .seconds(30),
        maxTransactionRetries: Int = 8,
        compaction: CompactionPolicy = CompactionPolicy(),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        maxSnapshotRetries: Int = 8
    ) {
        self.debounce = debounce
        self.maxTransactionRetries = maxTransactionRetries
        self.compaction = compaction
        self.jitter = jitter
        self.maxSnapshotRetries = maxSnapshotRetries
    }

    public static let `default` = CloudKitProviderOptions()
}

/// A Database Provider that propagates one `YDoc` across an iCloud user's
/// devices via CloudKit (ADR-0023/0024). It is an `actor`: the document is
/// shared with the app and other providers and the binding rejects concurrent
/// transactions, so the provider performs only short closure-scoped doc
/// transactions and retries on `transactionConflict`.
///
/// This type provides the push spine — observe, debounce, client-scoped-diff
/// capture, incremental enqueue, and lifecycle. Inbound apply (#65),
/// persistence/recovery (#66), compaction/GC (#67), and account handling (#68)
/// layer onto the hooks here.
public actor CloudKitProvider {
    public let documentName: String
    public let doc: YDoc
    public nonisolated let synced: AsyncStream<Bool>
    public nonisolated let errors: AsyncStream<Error>
    /// iCloud account-state changes the app can observe (ADR-0023).
    public nonisolated let accountChanges: AsyncStream<CloudKitAccountChange>

    private let store: CloudKitSyncStore
    private let options: CloudKitProviderOptions
    private let capture = ClientDiffCapture()
    private let recoveryPlanner = RecoveryPlanner()
    private nonisolated let syncedContinuation: AsyncStream<Bool>.Continuation
    private nonisolated let errorsContinuation: AsyncStream<Error>.Continuation
    private nonisolated let accountChangesContinuation: AsyncStream<CloudKitAccountChange>.Continuation
    private nonisolated let teardownQueue = DispatchQueue(label: "SwiftYrsCloudKit.CloudKitProvider.teardown")

    private var clientID: UInt64 = 0
    /// The clock through which this session's writes are confirmed sent.
    private var marker: UInt32 = 0
    /// Open writer sessions whose authored edits are not yet confirmed uploaded
    /// (ADR-0024), persisted across launches. Normally 0–1 entries.
    private var drainSet: [UInt64: UInt32] = [:]
    /// Records computed at flush time, supplied to the engine at send time.
    private var pendingRecords: [CKRecord.ID: CKRecord] = [:]
    /// Incremental records known to exist in the cloud (own + fetched), keyed by
    /// record ID — the GC candidate set once a snapshot subsumes them.
    private var knownIncrementals: [CKRecord.ID: IncrementalSummary] = [:]
    /// The most recent snapshot state vector seen (own confirmed save or fetch),
    /// used by the herd-damping re-check.
    private var latestSnapshotStateVector: ClientClockMap?
    /// Outcome of the in-flight snapshot send, recorded by `handleSent`.
    private var confirmedSnapshotStateVector: YStateVector?
    private var snapshotConflictServerRecord: CKRecord?
    private var observation: Observation?
    private var debounceTask: Task<Void, Never>?
    private var started = false
    private var destroyed = false
    /// Set after an account sign-out/switch: ingress stops and nothing is
    /// enqueued, so the existing doc never leaks into a new account (ADR-0023).
    private var suspended = false

    public init(
        documentName: String,
        doc: YDoc,
        store: CloudKitSyncStore,
        options: CloudKitProviderOptions = .default
    ) {
        self.documentName = documentName
        self.doc = doc
        self.store = store
        self.options = options

        let syncedPair = AsyncStream.makeStream(of: Bool.self)
        self.synced = syncedPair.stream
        self.syncedContinuation = syncedPair.continuation

        let errorsPair = AsyncStream.makeStream(of: Error.self)
        self.errors = errorsPair.stream
        self.errorsContinuation = errorsPair.continuation

        let accountPair = AsyncStream.makeStream(of: CloudKitAccountChange.self)
        self.accountChanges = accountPair.stream
        self.accountChangesContinuation = accountPair.continuation
    }

    public func start() async throws {
        guard !destroyed else { throw CloudKitProviderError.destroyed }
        guard !started else { return }

        try store.register(self, documentName: documentName)
        clientID = doc.clientID

        // The commit callback fires synchronously on the committing thread, so
        // it must never touch the doc — it only schedules a debounced flush.
        observation = try doc.observeUpdates { [weak self] event in
            guard let self, case .update = event else { return }
            Task { await self.scheduleFlush() }
        }
        started = true

        // Recover prior sessions whose edits never confirmed (chained crashes
        // leave more than one open clientID), then register this session.
        let priorOpenClients = loadDrainSet()
        drainSet = priorOpenClients
        drainSet[clientID] = marker
        persistDrainSet()
        try await recover(priorOpenClients: priorOpenClients)

        syncedContinuation.yield(true)
    }

    /// Flush now: capture this session's outstanding diff, enqueue it as an
    /// incremental record, and send. Cancels any pending debounce.
    public func flush() async throws {
        debounceTask?.cancel()
        debounceTask = nil
        try await performFlush()
    }

    /// Called when the app enters the background, to capture the latest edits
    /// before a possible kill (ADR-0023). Equivalent to an explicit `flush()`.
    public func flushForBackground() async throws {
        try await flush()
    }

    /// Pull remote changes from CloudKit and apply them to the doc. Inbound
    /// records arrive through the engine's `fetchedChanges` event.
    public func fetch() async throws {
        guard started, !destroyed else { return }
        try await store.fetchChanges()
    }

    /// Force a compaction now: write the shared full-state snapshot (resolving
    /// conflicts by merge) and GC the incrementals it subsumes. Threshold and
    /// herd-damping checks are bypassed.
    public func compact() async {
        guard started, !destroyed else { return }
        await writeSnapshot()
    }

    private func scheduleFlush() {
        guard started, !destroyed, !suspended else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce = options.debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.debouncedFlush()
        }
    }

    private func debouncedFlush() async {
        guard started, !destroyed else { return }
        debounceTask = nil
        do {
            try await performFlush()
        } catch {
            errorsContinuation.yield(error)
        }
    }

    private func performFlush() async throws {
        guard started, !destroyed, !suspended else { return }
        guard let captured = try await captureOutstandingDiff() else { return }

        if let recordID = enqueueIncremental(
            clientID: clientID,
            fromClock: marker,
            toClock: captured.toClock,
            update: captured.update
        ) {
            await store.enqueueSave(recordID)
        }
        try await store.sendChanges()
        await compactIfNeeded()
    }

    /// On (re)start, re-derive and re-enqueue each prior open session's
    /// outstanding client-scoped diff so un-confirmed edits propagate, retiring
    /// any whose diff is empty (ADR-0024). The current session is excluded — it
    /// has authored nothing yet.
    private func recover(priorOpenClients: [UInt64: UInt32]) async throws {
        let others = priorOpenClients.filter { $0.key != clientID }
        guard !others.isEmpty else { return }

        let plan = try recoveryPlanner.plan(openClients: others, in: doc)
        for retiredID in plan.retired {
            drainSet[retiredID] = nil
        }
        var enqueued = false
        for resend in plan.resends {
            let toClock = try capture.currentClock(in: doc, clientID: resend.clientID)
            if let recordID = enqueueIncremental(
                clientID: resend.clientID,
                fromClock: resend.fromClock,
                toClock: toClock,
                update: resend.update
            ) {
                await store.enqueueSave(recordID)
                enqueued = true
            }
        }
        persistDrainSet()
        if enqueued {
            try await store.sendChanges()
        }
    }

    @discardableResult
    private func enqueueIncremental(
        clientID: UInt64,
        fromClock: UInt32,
        toClock: UInt32,
        update: YUpdate
    ) -> CKRecord.ID? {
        let recordID = store.codec.incrementalRecordID(
            documentName: documentName,
            clientID: clientID,
            fromClock: fromClock,
            toClock: toClock
        )
        guard let record = try? store.codec.encodeIncremental(
            CloudKitIncrementalRecordPayload(
                documentName: documentName,
                clientID: clientID,
                fromClock: fromClock,
                toClock: toClock,
                update: update
            )
        ) else {
            return nil
        }
        pendingRecords[recordID] = record
        return recordID
    }

    private func loadDrainSet() -> [UInt64: UInt32] {
        guard let data = try? store.metadataStore.data(
            forKey: CloudKitSyncStateKeys.drainSet,
            documentName: documentName
        ), let decoded = try? DrainSetCodec.decode(data) else {
            return [:]
        }
        return decoded
    }

    private func persistDrainSet() {
        guard let data = try? DrainSetCodec.encode(drainSet) else { return }
        try? store.metadataStore.set(
            data,
            forKey: CloudKitSyncStateKeys.drainSet,
            documentName: documentName
        )
    }

    // MARK: Compaction / GC (ADR-0023)

    /// If the incremental backlog crosses the threshold, write the shared
    /// full-state snapshot and GC the incrementals it subsumes. Jitter plus a
    /// pre-compaction fetch dampen the multi-device herd: if a freshly-fetched
    /// snapshot already subsumes the backlog, this trailing device backs off.
    private func compactIfNeeded() async {
        guard started, !destroyed, !suspended else { return }
        let summaries = Array(knownIncrementals.values)
        let bytes = summaries.reduce(0) { $0 + $1.byteCount }
        guard options.compaction.shouldCompact(
            incrementalCount: summaries.count,
            incrementalBytes: bytes,
            jitter: options.jitter()
        ) else { return }

        try? await store.fetchChanges()
        if let latest = latestSnapshotStateVector {
            let confirmed = ConfirmedSnapshot(confirmedSaved: latest)
            guard options.compaction.shouldProceedAfterFetch(
                incrementals: Array(knownIncrementals.values),
                latestSnapshot: confirmed,
                jitter: options.jitter()
            ) else { return }
        }

        await writeSnapshot()
    }

    /// Write the full-state snapshot, resolving `serverRecordChanged` by
    /// applying the server snapshot (lossless — merge only grows state),
    /// recomputing, and retrying. Once the snapshot is confirmed saved, GC the
    /// incrementals it subsumes.
    private func writeSnapshot() async {
        var attempts = 0
        while attempts < options.maxSnapshotRetries {
            attempts += 1
            confirmedSnapshotStateVector = nil
            snapshotConflictServerRecord = nil
            do {
                let full = try await captureFullState()
                let recordID = store.codec.snapshotRecordID(documentName: documentName)
                pendingRecords[recordID] = try store.codec.encodeSnapshot(
                    CloudKitSnapshotRecordPayload(
                        documentName: documentName,
                        update: full.update,
                        stateVector: full.stateVector
                    )
                )
                await store.enqueueSave(recordID)
                try await store.sendChanges()
            } catch {
                errorsContinuation.yield(error)
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

    /// Delete incrementals fully contained in the confirmed snapshot — safe
    /// cross-writer because the stored SV proves subsumption; incrementals
    /// authored after the snapshot are retained.
    private func gcSubsumed(confirmedStateVector: YStateVector) async {
        guard let confirmed = try? ConfirmedSnapshot(confirmedSaved: confirmedStateVector) else { return }
        let subsumed = options.compaction.subsumedIncrementals(
            Array(knownIncrementals.values),
            by: confirmed
        )
        guard !subsumed.isEmpty else { return }
        for summary in subsumed {
            let recordID = store.codec.incrementalRecordID(
                documentName: documentName,
                clientID: summary.clientID,
                fromClock: summary.fromClock,
                toClock: summary.toClock
            )
            knownIncrementals[recordID] = nil
            await store.enqueueDelete(recordID)
        }
        try? await store.sendChanges()
    }

    /// Capture this session's client-scoped diff since the marker, retrying on
    /// `transactionConflict` so a concurrent app write does not lose the flush.
    private func captureOutstandingDiff() async throws -> (update: YUpdate, toClock: UInt32)? {
        var attempts = 0
        while true {
            do {
                let current = try capture.currentClock(in: doc, clientID: clientID)
                guard current > marker else { return nil }
                guard let update = try capture.clientDiff(
                    in: doc,
                    clientID: clientID,
                    fromClock: marker
                ) else { return nil }
                return (update, current)
            } catch YError.transactionConflict {
                attempts += 1
                guard attempts < options.maxTransactionRetries else {
                    throw CloudKitProviderError.transactionConflict
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    // MARK: Handler callbacks (routed from the store)

    func recordToSave(_ recordID: CKRecord.ID) -> CKRecord? {
        suspended ? nil : pendingRecords[recordID]
    }

    /// Records the outcome of a send. The compaction flow reads
    /// `confirmedSnapshotStateVector` / `snapshotConflictServerRecord` after its
    /// `sendChanges()` returns to drive GC or the merge-retry.
    func handleSent(saved: [CKRecord], deleted: [CKRecord.ID], failed: [CloudKitSendFailure]) {
        let snapshotID = store.codec.snapshotRecordID(documentName: documentName)
        var drainSetChanged = false
        for record in saved {
            pendingRecords.removeValue(forKey: record.recordID)
            if record.recordType == CloudKitRecordType.snapshot {
                if let payload = try? store.codec.decodeSnapshot(record) {
                    confirmedSnapshotStateVector = payload.stateVector
                    latestSnapshotStateVector = try? ClientClockMap(decoding: payload.stateVector)
                }
                continue
            }
            guard let payload = try? store.codec.decodeIncremental(record) else { continue }
            trackIncremental(payload, recordID: record.recordID)
            if payload.clientID == clientID {
                marker = max(marker, payload.toClock)
                drainSet[clientID] = marker
            } else {
                drainSet[payload.clientID] = nil
            }
            drainSetChanged = true
        }
        if drainSetChanged {
            persistDrainSet()
        }
        for failure in failed {
            if failure.recordID == snapshotID, failure.error == .serverRecordChanged {
                snapshotConflictServerRecord = failure.serverRecord
            } else {
                errorsContinuation.yield(failure.error)
            }
        }
        if !saved.isEmpty {
            syncedContinuation.yield(true)
        }
    }

    private func trackIncremental(_ payload: CloudKitIncrementalRecordPayload, recordID: CKRecord.ID) {
        knownIncrementals[recordID] = IncrementalSummary(
            clientID: payload.clientID,
            fromClock: payload.fromClock,
            toClock: payload.toClock,
            byteCount: payload.update.data.count
        )
    }

    /// Apply remote records to the doc (ADR-0023). Yjs updates are commutative
    /// and idempotent, so applies are order-independent and safe to retry on
    /// `transactionConflict`. Deletions are GC of subsumed incrementals — their
    /// content already lives in the doc/snapshot — so they need no apply.
    ///
    /// This is echo-safe by construction: capture is client-scoped to *this*
    /// session's clientID, and applying another writer's update never advances
    /// our clientID's clock, so the flush that the apply schedules produces an
    /// empty diff and re-uploads nothing.
    func handleFetched(modified: [CKRecord], deleted: [CKRecord.ID]) async {
        var applied = false
        for record in modified {
            noteFetchedRecord(record)
            guard let update = decodeUpdate(from: record) else { continue }
            do {
                try await applyWithRetry(update)
                applied = true
            } catch {
                errorsContinuation.yield(error)
            }
        }
        for recordID in deleted {
            knownIncrementals[recordID] = nil
        }
        if applied {
            syncedContinuation.yield(true)
        }
    }

    /// Track fetched records so the GC candidate set and the herd-damping
    /// re-check see other devices' incrementals and the shared snapshot.
    private func noteFetchedRecord(_ record: CKRecord) {
        switch record.recordType {
        case CloudKitRecordType.incremental:
            if let payload = try? store.codec.decodeIncremental(record) {
                trackIncremental(payload, recordID: record.recordID)
            }
        case CloudKitRecordType.snapshot:
            if let payload = try? store.codec.decodeSnapshot(record) {
                latestSnapshotStateVector = try? ClientClockMap(decoding: payload.stateVector)
            }
        default:
            break
        }
    }

    private func decodeUpdate(from record: CKRecord) -> YUpdate? {
        do {
            switch record.recordType {
            case CloudKitRecordType.incremental:
                return try store.codec.decodeIncremental(record).update
            case CloudKitRecordType.snapshot:
                return try store.codec.decodeSnapshot(record).update
            default:
                return nil
            }
        } catch {
            errorsContinuation.yield(error)
            return nil
        }
    }

    private func applyWithRetry(_ update: YUpdate) async throws {
        var attempts = 0
        while true {
            do {
                try doc.apply(update)
                return
            } catch YError.transactionConflict {
                attempts += 1
                guard attempts < options.maxTransactionRetries else {
                    throw CloudKitProviderError.transactionConflict
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// React to an iCloud account change (ADR-0023). On a sign-out/switch, stop
    /// ingress and clear this document's local sync state; the existing doc is
    /// never auto-uploaded into the newly-signed-in account (the fate of its
    /// content is the app's decision).
    func handleAccountChange(_ change: CloudKitAccountChange) {
        accountChangesContinuation.yield(change)
        switch change {
        case .signOut, .switchAccounts:
            suspended = true
            debounceTask?.cancel()
            debounceTask = nil
            pendingRecords.removeAll()
            knownIncrementals.removeAll()
            drainSet.removeAll()
            try? store.metadataStore.removeData(
                forKey: CloudKitSyncStateKeys.drainSet,
                documentName: documentName
            )
        case .signIn:
            break
        }
    }

    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        let wasStarted = started
        started = false

        // Stop ingress before tearing down the native observation.
        debounceTask?.cancel()
        debounceTask = nil
        let observation = self.observation
        self.observation = nil

        if wasStarted {
            store.unregister(documentName: documentName)
        }

        // Foreign-threaded-library rule (CLAUDE.md): release the native handle
        // off the actor's executor, without awaiting it.
        teardownQueue.async {
            observation?.cancel()
        }

        syncedContinuation.finish()
        errorsContinuation.finish()
        accountChangesContinuation.finish()
    }
}

extension CloudKitSendError: Error {}
#endif
