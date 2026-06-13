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

    public init(debounce: Duration = .seconds(30), maxTransactionRetries: Int = 8) {
        self.debounce = debounce
        self.maxTransactionRetries = maxTransactionRetries
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

    private let store: CloudKitSyncStore
    private let options: CloudKitProviderOptions
    private let capture = ClientDiffCapture()
    private let recoveryPlanner = RecoveryPlanner()
    private nonisolated let syncedContinuation: AsyncStream<Bool>.Continuation
    private nonisolated let errorsContinuation: AsyncStream<Error>.Continuation
    private nonisolated let teardownQueue = DispatchQueue(label: "SwiftYrsCloudKit.CloudKitProvider.teardown")

    private var clientID: UInt64 = 0
    /// The clock through which this session's writes are confirmed sent.
    private var marker: UInt32 = 0
    /// Open writer sessions whose authored edits are not yet confirmed uploaded
    /// (ADR-0024), persisted across launches. Normally 0–1 entries.
    private var drainSet: [UInt64: UInt32] = [:]
    /// Records computed at flush time, supplied to the engine at send time.
    private var pendingRecords: [CKRecord.ID: CKRecord] = [:]
    private var observation: Observation?
    private var debounceTask: Task<Void, Never>?
    private var started = false
    private var destroyed = false

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

    private func scheduleFlush() {
        guard started, !destroyed else { return }
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
        guard started, !destroyed else { return }
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
        pendingRecords[recordID]
    }

    func handleSent(saved: [CKRecord], deleted: [CKRecord.ID], failed: [CloudKitSendFailure]) {
        var drainSetChanged = false
        for record in saved {
            guard pendingRecords.removeValue(forKey: record.recordID) != nil else { continue }
            guard let payload = try? store.codec.decodeIncremental(record) else { continue }
            if payload.clientID == clientID {
                // This session's writes are confirmed through toClock.
                marker = max(marker, payload.toClock)
                drainSet[clientID] = marker
            } else {
                // A prior dead session's full diff is confirmed → retire it.
                drainSet[payload.clientID] = nil
            }
            drainSetChanged = true
        }
        if drainSetChanged {
            persistDrainSet()
        }
        for failure in failed {
            errorsContinuation.yield(failure.error)
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
            guard let update = decodeUpdate(from: record) else { continue }
            do {
                try await applyWithRetry(update)
                applied = true
            } catch {
                errorsContinuation.yield(error)
            }
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

    /// Account-change handling (issue #68).
    func handleAccountChange(_ change: CloudKitAccountChange) {}

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
    }
}

extension CloudKitSendError: Error {}
#endif
