import Foundation

/// One JSON-encoded value in a ``CloudKitMetadataStore``, addressed by key and
/// document name.
///
/// The provider keeps several such values — the drain set, the known-record
/// registry, the inbound spool, the store's document index — and each was
/// otherwise the same eight lines of decode/mutate/encode/write. Sharing them
/// also makes error handling one decision instead of one per call site: a
/// failed write is reported through `reportError`, because silently losing a
/// spool write would silently lose the remote update it exists to protect.
struct PersistedValue<Value: Codable & Sendable>: Sendable {
    private let metadataStore: CloudKitMetadataStore
    private let key: String
    private let documentName: String
    private let empty: Value
    private let reportError: @Sendable (Error) -> Void

    init(
        metadataStore: CloudKitMetadataStore,
        key: String,
        documentName: String,
        empty: Value,
        reportError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.metadataStore = metadataStore
        self.key = key
        self.documentName = documentName
        self.empty = empty
        self.reportError = reportError
    }

    /// The stored value, or `empty` when nothing is stored. A value that fails
    /// to decode is reported and treated as absent — refusing to start because
    /// of corrupt bookkeeping would be worse than rebuilding it.
    func load() -> Value {
        do {
            guard let data = try metadataStore.data(forKey: key, documentName: documentName) else {
                return empty
            }
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            reportError(error)
            return empty
        }
    }

    /// Read, modify, write. Callers serialize their own access; this only makes
    /// the round trip one step.
    func mutate(_ body: (inout Value) -> Void) {
        var value = load()
        body(&value)
        store(value)
    }

    func store(_ value: Value) {
        do {
            try metadataStore.set(try JSONEncoder().encode(value), forKey: key, documentName: documentName)
        } catch {
            reportError(error)
        }
    }

    func clear() {
        do {
            try metadataStore.removeData(forKey: key, documentName: documentName)
        } catch {
            reportError(error)
        }
    }
}
