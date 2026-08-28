#if canImport(CloudKit)
import Foundation

/// The record names a store believes one document owns in the shared zone
/// (ADR-0025).
///
/// `CKSyncEngine` offers no query path, so deleting one document's records
/// requires remembering their IDs. The registry is fed from the engine's own
/// events — records the server confirmed saved, and records a fetch reported as
/// modified or deleted — which makes it *best-effort*: a crash between the
/// server accepting a record and the registry write leaves an orphan that only
/// the next snapshot cycle's GC collects. Zone removal, which needs no
/// registry, is the exact operation.
///
/// Mutations are read-modify-write, so the store serializes them along with its
/// other per-document bookkeeping.
struct KnownRecordRegistry: Sendable {
    private let persisted: PersistedValue<Set<String>>

    init(
        metadataStore: CloudKitMetadataStore,
        documentName: String,
        reportError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.persisted = PersistedValue(
            metadataStore: metadataStore,
            key: CloudKitSyncStateKeys.knownRecords,
            documentName: documentName,
            empty: [],
            reportError: reportError
        )
    }

    func recordNames() -> Set<String> {
        persisted.load()
    }

    func add(_ recordNames: some Sequence<String>, removing removals: some Sequence<String>) {
        persisted.mutate { names in
            names.formUnion(recordNames)
            names.subtract(removals)
        }
    }

    func clear() {
        persisted.clear()
    }
}
#endif
