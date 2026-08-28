#if canImport(CloudKit)
import Foundation

/// The record names a store believes each of its documents owns in the shared
/// zone, persisted through ``CloudKitMetadataStore`` (ADR-0025).
///
/// `CKSyncEngine` offers no query path, so deleting one document's records
/// requires remembering their IDs. The registry is fed from the engine's own
/// events — records the server confirmed saved, and records a fetch reported as
/// modified or deleted — which makes it *best-effort*: a crash between the
/// server accepting a record and the registry write leaves an orphan that only
/// the next snapshot cycle's GC collects. Zone removal, which needs no
/// registry, is the exact operation.
///
/// Every accessor reads and writes through the metadata store rather than
/// caching, so the on-disk set is the single source of truth and a crash can
/// never lose more than the write in flight.
struct KnownRecordRegistry {
    private let metadataStore: CloudKitMetadataStore

    init(metadataStore: CloudKitMetadataStore) {
        self.metadataStore = metadataStore
    }

    /// Every document this store has ever recorded a record for — the set
    /// zone-wide cleanup walks.
    var documentNames: Set<String> {
        decode(
            key: CloudKitSyncStateKeys.knownDocuments,
            documentName: CloudKitSyncStateKeys.storeNamespace
        )
    }

    func recordNames(forDocument documentName: String) -> Set<String> {
        decode(key: CloudKitSyncStateKeys.knownRecords, documentName: documentName)
    }

    func add(_ recordNames: some Sequence<String>, forDocument documentName: String) {
        var names = self.recordNames(forDocument: documentName)
        let before = names.count
        names.formUnion(recordNames)
        guard names.count != before else { return }
        encode(names, key: CloudKitSyncStateKeys.knownRecords, documentName: documentName)
        rememberDocument(documentName)
    }

    func remove(_ recordNames: some Sequence<String>, forDocument documentName: String) {
        var names = self.recordNames(forDocument: documentName)
        let before = names.count
        names.subtract(recordNames)
        guard names.count != before else { return }
        encode(names, key: CloudKitSyncStateKeys.knownRecords, documentName: documentName)
    }

    /// Forget one document entirely, including its membership in
    /// ``documentNames``.
    func clear(forDocument documentName: String) {
        try? metadataStore.removeData(
            forKey: CloudKitSyncStateKeys.knownRecords,
            documentName: documentName
        )
        var documents = documentNames
        guard documents.remove(documentName) != nil else { return }
        encode(
            documents,
            key: CloudKitSyncStateKeys.knownDocuments,
            documentName: CloudKitSyncStateKeys.storeNamespace
        )
    }

    private func rememberDocument(_ documentName: String) {
        var documents = documentNames
        guard documents.insert(documentName).inserted else { return }
        encode(
            documents,
            key: CloudKitSyncStateKeys.knownDocuments,
            documentName: CloudKitSyncStateKeys.storeNamespace
        )
    }

    private func decode(key: String, documentName: String) -> Set<String> {
        guard let data = try? metadataStore.data(forKey: key, documentName: documentName),
              let names = try? JSONDecoder().decode(Set<String>.self, from: data)
        else {
            return []
        }
        return names
    }

    private func encode(_ names: Set<String>, key: String, documentName: String) {
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? metadataStore.set(data, forKey: key, documentName: documentName)
    }
}
#endif
