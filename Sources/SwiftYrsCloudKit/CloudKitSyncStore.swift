#if canImport(CloudKit)
import CloudKit
import Foundation

public enum CloudKitProviderError: Error, Equatable {
    case duplicateProvider(documentName: String)
    case destroyed
    case transactionConflict
}

/// Owns the single ``CloudKitSyncEngineAdapter`` (one engine per store) and the
/// record codec, and routes the engine's handler callbacks to the per-document
/// ``CloudKitProvider`` that owns the relevant zone — mirroring the
/// `SQLiteStore`/`SQLiteProvider` split (ADR-0023). Providers are held weakly so
/// a provider's `destroy()`/`deinit` is not blocked by the store.
public final class CloudKitSyncStore: CloudKitSyncEngineHandler, @unchecked Sendable {
    let adapter: CloudKitSyncEngineAdapter
    let codec: CloudKitRecordCodec
    let metadataStore: CloudKitMetadataStore

    private let lock = NSLock()
    private var providersByZone: [CKRecordZone.ID: WeakProvider] = [:]
    private var documentZones: [String: CKRecordZone.ID] = [:]

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
    }

    /// Wire the store as the engine's handler. Call once before starting providers.
    public func start() async {
        await adapter.setHandler(self)
    }

    // MARK: Provider registry

    func register(_ provider: CloudKitProvider, documentName: String) throws {
        let zoneID = codec.zoneID(forDocumentName: documentName)
        lock.lock()
        defer { lock.unlock() }
        if let existing = providersByZone[zoneID]?.provider, existing !== provider {
            throw CloudKitProviderError.duplicateProvider(documentName: documentName)
        }
        providersByZone[zoneID] = WeakProvider(provider)
        documentZones[documentName] = zoneID
    }

    func unregister(documentName: String) {
        lock.lock()
        defer { lock.unlock() }
        if let zoneID = documentZones.removeValue(forKey: documentName) {
            providersByZone[zoneID] = nil
        }
    }

    private func provider(for zoneID: CKRecordZone.ID) -> CloudKitProvider? {
        lock.lock()
        defer { lock.unlock() }
        return providersByZone[zoneID]?.provider
    }

    private func allProviders() -> [CloudKitProvider] {
        lock.lock()
        defer { lock.unlock() }
        return providersByZone.values.compactMap(\.provider)
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
        guard let provider = provider(for: recordID.zoneID) else { return nil }
        return await provider.recordToSave(recordID)
    }

    public func handleEvent(_ event: CloudKitSyncEvent) async {
        switch event {
        case .stateUpdate:
            // Engine-state serialization persistence is wired in issue #66.
            break
        case let .accountChange(change):
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
        let savedByZone = Dictionary(grouping: saved, by: { $0.recordID.zoneID })
        let failedByZone = Dictionary(grouping: failed, by: { $0.recordID.zoneID })
        let deletedByZone = Dictionary(grouping: deleted, by: { $0.zoneID })
        let zones = Set(savedByZone.keys).union(failedByZone.keys).union(deletedByZone.keys)
        for zoneID in zones {
            guard let provider = provider(for: zoneID) else { continue }
            await provider.handleSent(
                saved: savedByZone[zoneID] ?? [],
                deleted: deletedByZone[zoneID] ?? [],
                failed: failedByZone[zoneID] ?? []
            )
        }
    }

    private func dispatchFetched(modified: [CKRecord], deleted: [CKRecord.ID]) async {
        let modifiedByZone = Dictionary(grouping: modified, by: { $0.recordID.zoneID })
        let deletedByZone = Dictionary(grouping: deleted, by: { $0.zoneID })
        let zones = Set(modifiedByZone.keys).union(deletedByZone.keys)
        for zoneID in zones {
            guard let provider = provider(for: zoneID) else { continue }
            await provider.handleFetched(
                modified: modifiedByZone[zoneID] ?? [],
                deleted: deletedByZone[zoneID] ?? []
            )
        }
    }
}
#endif
