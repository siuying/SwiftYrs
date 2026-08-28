#if canImport(CloudKit)
import CloudKit
import Foundation

public enum CloudKitProviderError: Error, Equatable {
    case duplicateProvider(documentName: String)
    case activeProvider(documentName: String)
    case destroyed
    case transactionConflict
    /// A provider tried to attach to a document, or a zone, that is being
    /// removed. Removal and attachment cannot interleave without the removal
    /// clearing state the new provider just created.
    case removalInProgress(documentName: String?)
}

/// A record the store could not route to a document. Routing failures are
/// surfaced on ``CloudKitSyncStore/errors`` and the record is dropped: a name
/// the codec cannot parse never falls back to some other document (ADR-0025).
public enum CloudKitRoutingError: Error, Equatable {
    /// A record from a zone this store does not own.
    case foreignZone(zoneName: String, recordName: String)
}

/// Owns the single ``CloudKitSyncEngineAdapter`` (one engine per store), the
/// record codec, and the store's one CloudKit zone, and routes the engine's
/// handler callbacks to the per-document ``CloudKitProvider`` that owns each
/// record — mirroring the `SQLiteStore`/`SQLiteProvider` split (ADR-0023).
///
/// Every document of the store lives in the zone the codec was constructed with
/// (ADR-0025), so routing keys off the document encoded in each record *name*,
/// which is the only identity a deleted-record callback carries.
///
/// Inbound changes always take the same path: decode, append to the document's
/// persisted spool, then drain the spool into the provider if one is attached.
/// Nothing is applied that was not durably recorded first, so neither a lazily
/// started provider nor a crash mid-apply can lose a remote edit. Providers are
/// held weakly so a provider's `destroy()`/`deinit` is not blocked by the store.
public final class CloudKitSyncStore: CloudKitSyncEngineHandler, @unchecked Sendable {
    let adapter: CloudKitSyncEngineAdapter
    let codec: CloudKitRecordCodec
    let metadataStore: CloudKitMetadataStore

    /// Failures with no provider to report them to: unroutable record names,
    /// records from another store's zone, and failures to persist bookkeeping.
    public nonisolated let errors: AsyncStream<Error>
    private nonisolated let errorsContinuation: AsyncStream<Error>.Continuation

    /// Guards the provider registry and every per-document metadata mutation.
    /// Those mutations are read-modify-write against the metadata store, so
    /// concurrent engine callbacks would otherwise lose each other's writes.
    private let lock = NSLock()
    private var providersByDocument: [String: WeakProvider] = [:]
    private var removingDocuments: Set<String> = []
    private var removingZone = false

    private final class WeakProvider {
        weak var provider: CloudKitProvider?
        init(_ provider: CloudKitProvider) { self.provider = provider }
    }

    public init(
        adapter: CloudKitSyncEngineAdapter,
        codec: CloudKitRecordCodec,
        metadataStore: CloudKitMetadataStore
    ) {
        self.adapter = adapter
        self.codec = codec
        self.metadataStore = metadataStore

        let errorsPair = AsyncStream.makeStream(of: Error.self)
        self.errors = errorsPair.stream
        self.errorsContinuation = errorsPair.continuation
    }

    deinit {
        errorsContinuation.finish()
    }

    /// Wire the store as the engine's handler and restore persisted engine state
    /// so a relaunch resumes from its change token rather than cold-fetching.
    /// Call once before starting providers.
    public func start() async {
        await adapter.setHandler(self)
        if let state = try? metadataStore.data(
            forKey: CloudKitSyncStateKeys.engineState,
            documentName: CloudKitSyncStateKeys.storeNamespace
        ) {
            await adapter.loadState(state)
        }
    }

    // MARK: Provider registry

    /// Attach a provider and hand it everything fetched for its document while
    /// it was away, in arrival order, before it does anything else. Called by
    /// ``CloudKitProvider/start()``.
    func attach(_ provider: CloudKitProvider, documentName: String) async throws {
        try lock.withLock {
            if removingZone {
                throw CloudKitProviderError.removalInProgress(documentName: nil)
            }
            if removingDocuments.contains(documentName) {
                throw CloudKitProviderError.removalInProgress(documentName: documentName)
            }
            if let existing = providersByDocument[documentName]?.provider, existing !== provider {
                throw CloudKitProviderError.duplicateProvider(documentName: documentName)
            }
            providersByDocument[documentName] = WeakProvider(provider)
            rememberDocument(documentName)
        }
        await drainInboundSpool(into: provider, documentName: documentName)
    }

    func detach(documentName: String) {
        lock.withLock { providersByDocument[documentName] = nil }
    }

    /// Apply a document's spooled changes, oldest first, dropping each batch
    /// only once the provider has applied it. A crash before the drop replays
    /// the batch, which is harmless: yrs updates are idempotent and commutative.
    private func drainInboundSpool(into provider: CloudKitProvider, documentName: String) async {
        while true {
            let pending = lock.withLock { spool(for: documentName).pending() }
            guard let lastSequence = pending.last?.sequence else { return }
            await provider.handleFetched(pending.map(\.change))
            lock.withLock { spool(for: documentName).remove(throughSequence: lastSequence) }
        }
    }

    // MARK: Removal

    /// Delete one document's CloudKit records and local sync state, leaving the
    /// zone and every other document in it untouched — analogous to
    /// `SQLiteStore.removeDocument` (ADR-0023).
    ///
    /// This is *best-effort*: `CKSyncEngine` has no query path, so the store
    /// deletes the records it recorded in its known-record registry, and a
    /// record the registry missed (a crash between the server's accept and the
    /// registry write) survives until the next snapshot cycle's GC. Use
    /// ``removeZone()`` when the deletion must be exact.
    ///
    /// - Throws: ``CloudKitProviderError/activeProvider(documentName:)`` if a
    ///   provider for the document is still attached.
    public func removeDocument(named documentName: String) async throws {
        let recordNames = try lock.withLock {
            try beginRemoval(of: documentName)
            return knownRecords(for: documentName).recordNames()
        }
        defer { lock.withLock { removingDocuments.remove(documentName) } }

        for recordName in recordNames {
            await adapter.enqueueDelete(CKRecord.ID(recordName: recordName, zoneID: codec.zoneID))
        }
        if !recordNames.isEmpty {
            try await adapter.sendChanges()
        }
        lock.withLock { clearLocalState(forDocument: documentName) }
    }

    /// Delete this store's whole zone — every document's records at once — and
    /// clear all zone-scoped local state. This is the dataset-level delete (the
    /// consumer's "delete the vault"), and unlike ``removeDocument(named:)`` it
    /// is exact: it needs no registry of record IDs.
    ///
    /// The engine's persisted state is deliberately kept: it is store-scoped,
    /// not zone-scoped, and dropping it would force a cold re-fetch of a zone
    /// that no longer exists.
    ///
    /// - Throws: ``CloudKitProviderError/activeProvider(documentName:)`` if any
    ///   provider is still attached, since a live provider would immediately
    ///   re-create the zone.
    public func removeZone() async throws {
        try lock.withLock {
            if removingZone {
                throw CloudKitProviderError.removalInProgress(documentName: nil)
            }
            // Sorted, so the reported document does not depend on dictionary
            // order when several are attached.
            if let attached = providersByDocument.filter({ $0.value.provider != nil }).keys.min() {
                throw CloudKitProviderError.activeProvider(documentName: attached)
            }
            removingZone = true
        }
        defer { lock.withLock { removingZone = false } }

        try await adapter.deleteZone(codec.zoneID)
        lock.withLock {
            for documentName in documentIndex.load() {
                clearLocalState(forDocument: documentName)
            }
            documentIndex.clear()
        }
    }

    /// Clear store-level CloudKit sync state on an account sign-out/switch so a
    /// new account never resumes the previous account's engine state.
    func clearEngineState() {
        try? metadataStore.removeData(
            forKey: CloudKitSyncStateKeys.engineState,
            documentName: CloudKitSyncStateKeys.storeNamespace
        )
    }

    /// - Precondition: `lock` is held.
    private func beginRemoval(of documentName: String) throws {
        if removingZone {
            throw CloudKitProviderError.removalInProgress(documentName: nil)
        }
        if removingDocuments.contains(documentName) {
            throw CloudKitProviderError.removalInProgress(documentName: documentName)
        }
        if providersByDocument[documentName]?.provider != nil {
            throw CloudKitProviderError.activeProvider(documentName: documentName)
        }
        removingDocuments.insert(documentName)
    }

    /// - Precondition: `lock` is held.
    private func clearLocalState(forDocument documentName: String) {
        drainSet(for: documentName).clear()
        knownRecords(for: documentName).clear()
        spool(for: documentName).clear()
        documentIndex.mutate { $0.remove(documentName) }
    }

    // MARK: Per-document persisted state

    /// Every document this store holds local state for, so zone removal can
    /// find all of it. A document joins on its first attach or first fetched
    /// change, whichever comes first.
    private var documentIndex: PersistedValue<Set<String>> {
        PersistedValue(
            metadataStore: metadataStore,
            key: CloudKitSyncStateKeys.knownDocuments,
            documentName: CloudKitSyncStateKeys.storeNamespace,
            empty: [],
            reportError: report
        )
    }

    private func spool(for documentName: String) -> InboundSpool {
        InboundSpool(metadataStore: metadataStore, documentName: documentName, reportError: report)
    }

    private func knownRecords(for documentName: String) -> KnownRecordRegistry {
        KnownRecordRegistry(metadataStore: metadataStore, documentName: documentName, reportError: report)
    }

    private func drainSet(for documentName: String) -> DrainSetManager {
        DrainSetManager(metadataStore: metadataStore, documentName: documentName, reportError: report)
    }

    private var report: @Sendable (Error) -> Void {
        { [errorsContinuation] error in errorsContinuation.yield(error) }
    }

    /// - Precondition: `lock` is held.
    private func rememberDocument(_ documentName: String) {
        documentIndex.mutate { $0.insert(documentName) }
    }

    private func provider(forDocument documentName: String) -> CloudKitProvider? {
        lock.withLock { providersByDocument[documentName]?.provider }
    }

    private func allProviders() -> [CloudKitProvider] {
        lock.withLock { providersByDocument.values.compactMap(\.provider) }
    }

    // MARK: Engine passthrough (used by providers)

    func enqueueSave(_ recordID: CKRecord.ID) async {
        await adapter.enqueueSave(recordID)
    }

    func enqueueDelete(_ recordID: CKRecord.ID) async {
        await adapter.enqueueDelete(recordID)
    }

    func sendChanges() async throws {
        try await adapter.sendChanges()
    }

    func fetchChanges() async throws {
        try await adapter.fetchChanges()
    }

    // MARK: CloudKitSyncEngineHandler

    public func recordToSave(_ recordID: CKRecord.ID) async -> CKRecord? {
        guard let documentName = routedDocumentName(for: recordID),
              let provider = provider(forDocument: documentName)
        else {
            return nil
        }
        return await provider.recordToSave(recordID)
    }

    public func handleEvent(_ event: CloudKitSyncEvent) async {
        switch event {
        case let .stateUpdate(data):
            try? metadataStore.set(
                data,
                forKey: CloudKitSyncStateKeys.engineState,
                documentName: CloudKitSyncStateKeys.storeNamespace
            )
        case let .accountChange(change):
            // A sign-out/switch must not let a new account resume the old one's
            // engine state (ADR-0023).
            if change == .signOut || change == .switchAccounts {
                clearEngineState()
            }
            for provider in allProviders() {
                await provider.handleAccountChange(change)
            }
        case let .fetchedChanges(modified, deleted):
            await dispatchFetched(modified: modified, deleted: deleted)
        case let .sentChanges(saved, deleted, failed):
            await dispatchSent(saved: saved, deleted: deleted, failed: failed)
        }
    }

    /// The outcome of this store's own writes. It goes straight to the owning
    /// provider — unlike a fetch, there is nothing to replay later, and the
    /// provider is by definition the one that asked for the write.
    private func dispatchSent(
        saved: [CKRecord],
        deleted: [CKRecord.ID],
        failed: [CloudKitSendFailure]
    ) async {
        let batch = RoutedBatch(
            modified: saved,
            deleted: deleted,
            failed: failed,
            route: routedDocumentName(for:)
        )
        for documentName in batch.documentNames {
            lock.withLock { noteRecords(of: batch, forDocument: documentName) }
            guard let provider = provider(forDocument: documentName) else { continue }
            await provider.handleSent(
                saved: batch.modified(for: documentName),
                deleted: batch.deleted(for: documentName),
                failed: batch.failed(for: documentName)
            )
        }
    }

    /// Remote changes. Every one is spooled before it is applied, so the drain
    /// is the only path into a provider and arrival order needs no separate
    /// guard.
    private func dispatchFetched(modified: [CKRecord], deleted: [CKRecord.ID]) async {
        let batch = RoutedBatch(modified: modified, deleted: deleted, failed: [], route: routedDocumentName(for:))
        for documentName in batch.documentNames {
            // Decode while this callback still owns any CKAsset file.
            let changes = inboundChanges(
                modified: batch.modified(for: documentName),
                deleted: batch.deleted(for: documentName)
            )
            let spooled = lock.withLock { () -> Bool in
                guard !removingZone, !removingDocuments.contains(documentName) else { return false }
                noteRecords(of: batch, forDocument: documentName)
                spool(for: documentName).append(changes)
                rememberDocument(documentName)
                return true
            }
            guard spooled, let provider = provider(forDocument: documentName) else { continue }
            await drainInboundSpool(into: provider, documentName: documentName)
        }
    }

    /// - Precondition: `lock` is held.
    private func noteRecords(of batch: RoutedBatch, forDocument documentName: String) {
        knownRecords(for: documentName).add(
            batch.modified(for: documentName).map(\.recordID.recordName),
            removing: batch.deleted(for: documentName).map(\.recordName)
        )
    }

    private func inboundChanges(modified: [CKRecord], deleted: [CKRecord.ID]) -> [InboundChange] {
        var changes: [InboundChange] = []
        for record in modified {
            do {
                switch record.recordType {
                case CloudKitRecordType.incremental:
                    changes.append(InboundChange(try codec.decodeIncremental(record)))
                case CloudKitRecordType.snapshot:
                    changes.append(InboundChange(try codec.decodeSnapshot(record)))
                default:
                    continue
                }
            } catch {
                errorsContinuation.yield(error)
            }
        }
        changes.append(contentsOf: deleted.map { .deletion(recordName: $0.recordName) })
        return changes
    }

    /// The document a record ID belongs to, or `nil` having reported why not.
    private func routedDocumentName(for recordID: CKRecord.ID) -> String? {
        guard recordID.zoneID == codec.zoneID else {
            errorsContinuation.yield(
                CloudKitRoutingError.foreignZone(
                    zoneName: recordID.zoneID.zoneName,
                    recordName: recordID.recordName
                )
            )
            return nil
        }
        do {
            return try codec.documentName(fromRecordName: recordID.recordName)
        } catch {
            errorsContinuation.yield(error)
            return nil
        }
    }
}

/// One engine callback's payloads, grouped by the document each record name
/// names. Records that do not route are left out — the routing closure reports
/// them — so a malformed name can never reach a provider.
private struct RoutedBatch {
    private let modifiedByDocument: [String: [CKRecord]]
    private let deletedByDocument: [String: [CKRecord.ID]]
    private let failedByDocument: [String: [CloudKitSendFailure]]
    let documentNames: Set<String>

    init(
        modified: [CKRecord],
        deleted: [CKRecord.ID],
        failed: [CloudKitSendFailure],
        route: (CKRecord.ID) -> String?
    ) {
        modifiedByDocument = Self.grouped(modified, by: route, recordID: \.recordID)
        deletedByDocument = Self.grouped(deleted, by: route, recordID: \.self)
        failedByDocument = Self.grouped(failed, by: route, recordID: \.recordID)
        documentNames = Set(modifiedByDocument.keys)
            .union(deletedByDocument.keys)
            .union(failedByDocument.keys)
    }

    func modified(for documentName: String) -> [CKRecord] { modifiedByDocument[documentName] ?? [] }
    func deleted(for documentName: String) -> [CKRecord.ID] { deletedByDocument[documentName] ?? [] }
    func failed(for documentName: String) -> [CloudKitSendFailure] { failedByDocument[documentName] ?? [] }

    /// Groups while preserving arrival order within each document.
    private static func grouped<Element>(
        _ elements: [Element],
        by route: (CKRecord.ID) -> String?,
        recordID: KeyPath<Element, CKRecord.ID>
    ) -> [String: [Element]] {
        var grouped: [String: [Element]] = [:]
        for element in elements {
            guard let documentName = route(element[keyPath: recordID]) else { continue }
            grouped[documentName, default: []].append(element)
        }
        return grouped
    }
}
#endif
