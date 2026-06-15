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
    private var drainSetManager: DrainSetManager
    private let recordQueue: RecordQueue
    private let snapshotWriter: SnapshotWriter
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
        let recordQueue = RecordQueue()
        self.recordQueue = recordQueue
        self.drainSetManager = DrainSetManager(metadataStore: store.metadataStore, documentName: documentName)
        self.snapshotWriter = SnapshotWriter(
            documentName: documentName,
            doc: doc,
            store: store,
            options: options,
            recordQueue: recordQueue
        )

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
        let priorOpenClients = drainSetManager.load()
        var currentDrainSet = priorOpenClients
        currentDrainSet[clientID] = marker
        drainSetManager.replace(with: currentDrainSet)
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
            drainSetManager.retire(clientID: retiredID)
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
        recordQueue.enqueue(record)
        return recordID
    }

    // MARK: Compaction / GC (ADR-0023)

    /// If the incremental backlog crosses the threshold, write the shared
    /// full-state snapshot and GC the incrementals it subsumes. Jitter plus a
    /// pre-compaction fetch dampen the multi-device herd: if a freshly-fetched
    /// snapshot already subsumes the backlog, this trailing device backs off.
    private func compactIfNeeded() async {
        guard started, !destroyed, !suspended else { return }
        let summaries = snapshotWriter.incrementalSummaries
        let bytes = summaries.reduce(0) { $0 + $1.byteCount }
        guard options.compaction.shouldCompact(
            incrementalCount: summaries.count,
            incrementalBytes: bytes,
            jitter: options.jitter()
        ) else { return }

        try? await store.fetchChanges()
        if let latest = snapshotWriter.latestSnapshotStateVector {
            let confirmed = ConfirmedSnapshot(confirmedSaved: latest)
            guard options.compaction.shouldProceedAfterFetch(
                incrementals: snapshotWriter.incrementalSummaries,
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
        await snapshotWriter.writeSnapshot(
            applyWithRetry: { [weak self] update in
                try await self?.applyWithRetry(update)
            },
            reportError: { [errorsContinuation] error in
                errorsContinuation.yield(error)
            }
        )
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
        suspended ? nil : recordQueue.record(toSave: recordID)
    }

    /// Records the outcome of a send. Snapshot outcomes are forwarded to
    /// `SnapshotWriter`, whose in-flight compaction reads them after
    /// `sendChanges()` returns to drive GC or the merge-retry.
    func handleSent(saved: [CKRecord], deleted: [CKRecord.ID], failed: [CloudKitSendFailure]) {
        for record in saved {
            recordQueue.remove(record.recordID)
            if snapshotWriter.handleSavedSnapshot(record) {
                continue
            }
            guard let payload = try? store.codec.decodeIncremental(record) else { continue }
            snapshotWriter.trackIncremental(payload, recordID: record.recordID)
            if payload.clientID == clientID {
                marker = max(marker, payload.toClock)
                drainSetManager.update(clientID: clientID, marker: marker)
            } else {
                drainSetManager.retire(clientID: payload.clientID)
            }
        }
        for failure in failed {
            if !snapshotWriter.handleSnapshotFailure(failure) {
                errorsContinuation.yield(failure.error)
            }
        }
        if !saved.isEmpty {
            syncedContinuation.yield(true)
        }
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
            snapshotWriter.noteFetchedRecord(record)
            guard let update = decodeUpdate(from: record) else { continue }
            do {
                try await applyWithRetry(update)
                applied = true
            } catch {
                errorsContinuation.yield(error)
            }
        }
        for recordID in deleted {
            snapshotWriter.removeKnownIncremental(recordID)
        }
        if applied {
            syncedContinuation.yield(true)
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
            recordQueue.removeAll()
            snapshotWriter.removeAllKnownIncrementals()
            drainSetManager.clear()
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
