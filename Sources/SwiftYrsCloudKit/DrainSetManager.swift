#if canImport(CloudKit)
import Foundation

/// The per-document open-clientID drain set `{clientID: fromClock}` (ADR-0024),
/// persisted as JSON with string keys because a `UInt64`-keyed dictionary would
/// otherwise encode as a flat array.
struct DrainSet: Codable, Equatable, Sendable {
    var clocks: [UInt64: UInt32]

    init(clocks: [UInt64: UInt32] = [:]) {
        self.clocks = clocks
    }

    init(from decoder: any Decoder) throws {
        let stringKeyed = try decoder.singleValueContainer().decode([String: UInt32].self)
        clocks = [:]
        for (key, value) in stringKeyed {
            guard let clientID = UInt64(key) else { continue }
            clocks[clientID] = value
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: clocks.map { (String($0.key), $0.value) }))
    }
}

/// Reads and writes one document's drain set (ADR-0024). Which sessions still
/// have unconfirmed edits is durable state, so every mutation writes through.
struct DrainSetManager: Sendable {
    private let persisted: PersistedValue<DrainSet>

    init(
        metadataStore: CloudKitMetadataStore,
        documentName: String,
        reportError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.persisted = PersistedValue(
            metadataStore: metadataStore,
            key: CloudKitSyncStateKeys.drainSet,
            documentName: documentName,
            empty: DrainSet(),
            reportError: reportError
        )
    }

    func load() -> [UInt64: UInt32] {
        persisted.load().clocks
    }

    func replace(with clocks: [UInt64: UInt32]) {
        persisted.store(DrainSet(clocks: clocks))
    }

    func update(clientID: UInt64, marker: UInt32) {
        persisted.mutate { $0.clocks[clientID] = marker }
    }

    func retire(clientID: UInt64) {
        persisted.mutate { $0.clocks[clientID] = nil }
    }

    func clear() {
        persisted.clear()
    }
}
#endif
