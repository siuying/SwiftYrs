import Foundation

/// Metadata keys and namespaces the provider persists through the injected
/// sync-state store (ADR-0023/0024). All values are key/value only.
public enum CloudKitSyncStateKeys {
    /// Per-document open-clientID drain set `{clientID: fromClock}` (ADR-0024).
    public static let drainSet = "cloudkit.drainSet"

    /// Reserved document name for store-level (single-engine) state.
    public static let storeNamespace = "__swiftyrs_cloudkit_store__"
    /// The `CKSyncEngine.State.Serialization`; losing it forces a cold re-fetch.
    public static let engineState = "cloudkit.engineState"
}

/// Codec for the drain set persisted as JSON `{ "<clientID>": fromClock }`.
enum DrainSetCodec {
    static func encode(_ drainSet: [UInt64: UInt32]) throws -> Data {
        let stringKeyed = Dictionary(uniqueKeysWithValues: drainSet.map { (String($0.key), $0.value) })
        return try JSONEncoder().encode(stringKeyed)
    }

    static func decode(_ data: Data) throws -> [UInt64: UInt32] {
        let stringKeyed = try JSONDecoder().decode([String: UInt32].self, from: data)
        var result: [UInt64: UInt32] = [:]
        for (key, value) in stringKeyed {
            guard let clientID = UInt64(key) else { continue }
            result[clientID] = value
        }
        return result
    }
}
