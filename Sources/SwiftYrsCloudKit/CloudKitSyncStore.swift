#if canImport(CloudKit)
import CloudKit
import Foundation

public enum CloudKitProviderError: Error, Equatable {
    case duplicateProvider(documentName: String)
    case activeProvider(documentName: String)
    case destroyed
    case transactionConflict
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
/// which is the only identity a deleted-record callback carries. Providers are
/// held weakly so a provider's `destroy()`/`deinit` is not blocked by the store.
public final class CloudKitSyncStore: CloudKitSyncEngineHandler, @unchecked Sendable {
    let adapter: CloudKitSyncEngineAdapter
    let codec: CloudKitRecordCodec
    let metadataStore: CloudKitMetadataStore

    /// Failures with no provider to report them to: unroutable record names,
    /// and records from another store's zone.
    public nonisolated let errors: AsyncStream<Error>
    private nonisolated let errorsContinuation: AsyncStream<Error>.Continuation

    private let lock = NSLock()
    private var providersByDocument: [String: WeakProvider] = [:]
    private let knownRecords: KnownRecordRegistry

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
        self.knownRecords = KnownRecordRegistry(metadataStore: metadataStore)

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

    func register(_ provider: CloudKitProvider, documentName: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let existing = providersByDocument[documentName]?.provider, existing !== provider {
            throw CloudKitProviderError.duplicateProvider(documentName: documentName)
        }
        providersByDocument[documentName] = WeakProvider(provider)
    }

    func unregister(documentName: String) {
        lock.lock()
        defer { lock.unlock() }
        providersByDocument[documentName] = nil
    }

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
        if provider(forDocument: documentName) != nil {
            throw CloudKitProviderError.activeProvider(documentName: documentName)
        }
        let recordNames = knownRecords.recordNames(forDocument: documentName)
        for recordName in recordNames {
            await adapter.enqueueDelete(CKRecord.ID(recordName: recordName, zoneID: codec.zoneID))
        }
        if !recordNames.isEmpty {
            try await adapter.sendChanges()
        }
        clearLocalState(forDocument: documentName)
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
        if let documentName = attachedDocumentName() {
            throw CloudKitProviderError.activeProvider(documentName: documentName)
        }
        try await adapter.deleteZone(codec.zoneID)
        for documentName in knownRecords.documentNames {
            clearLocalState(forDocument: documentName)
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

    private func clearLocalState(forDocument documentName: String) {
        var drainSetManager = DrainSetManager(metadataStore: metadataStore, documentName: documentName)
        drainSetManager.clear()
        knownRecords.clear(forDocument: documentName)
    }

    private func provider(forDocument documentName: String) -> CloudKitProvider? {
        lock.lock()
        defer { lock.unlock() }
        return providersByDocument[documentName]?.provider
    }

    private func attachedDocumentName() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return providersByDocument.first { $0.value.provider != nil }?.key
    }

    private func allProviders() -> [CloudKitProvider] {
        lock.lock()
        defer { lock.unlock() }
        return providersByDocument.values.compactMap(\.provider)
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
        guard let documentName = routedDocumentName(for: recordID) else { return nil }
        guard let provider = provider(forDocument: documentName) else { return nil }
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

    private func dispatchSent(
        saved: [CKRecord],
        deleted: [CKRecord.ID],
        failed: [CloudKitSendFailure]
    ) async {
        let savedByDocument = groupByDocument(saved, recordID: \.recordID)
        let failedByDocument = groupByDocument(failed, recordID: \.recordID)
        let deletedByDocument = groupByDocument(deleted, recordID: \.self)

        for (documentName, records) in savedByDocument {
            knownRecords.add(records.map(\.recordID.recordName), forDocument: documentName)
        }
        for (documentName, recordIDs) in deletedByDocument {
            knownRecords.remove(recordIDs.map(\.recordName), forDocument: documentName)
        }

        let documents = Set(savedByDocument.keys)
            .union(failedByDocument.keys)
            .union(deletedByDocument.keys)
        for documentName in documents {
            guard let provider = provider(forDocument: documentName) else { continue }
            await provider.handleSent(
                saved: savedByDocument[documentName] ?? [],
                deleted: deletedByDocument[documentName] ?? [],
                failed: failedByDocument[documentName] ?? []
            )
        }
    }

    private func dispatchFetched(modified: [CKRecord], deleted: [CKRecord.ID]) async {
        let modifiedByDocument = groupByDocument(modified, recordID: \.recordID)
        let deletedByDocument = groupByDocument(deleted, recordID: \.self)

        for (documentName, records) in modifiedByDocument {
            knownRecords.add(records.map(\.recordID.recordName), forDocument: documentName)
        }
        for (documentName, recordIDs) in deletedByDocument {
            knownRecords.remove(recordIDs.map(\.recordName), forDocument: documentName)
        }

        let documents = Set(modifiedByDocument.keys).union(deletedByDocument.keys)
        for documentName in documents {
            guard let provider = provider(forDocument: documentName) else { continue }
            await provider.handleFetched(
                modified: modifiedByDocument[documentName] ?? [],
                deleted: deletedByDocument[documentName] ?? []
            )
        }
    }

    /// Group engine payloads by the document encoded in each record name,
    /// preserving arrival order within a document. Anything unroutable is
    /// reported on ``errors`` and left out.
    private func groupByDocument<Element>(
        _ elements: [Element],
        recordID: KeyPath<Element, CKRecord.ID>
    ) -> [String: [Element]] {
        var grouped: [String: [Element]] = [:]
        for element in elements {
            guard let documentName = routedDocumentName(for: element[keyPath: recordID]) else {
                continue
            }
            grouped[documentName, default: []].append(element)
        }
        return grouped
    }

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
#endif
