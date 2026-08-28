import Foundation

/// Metadata keys and namespaces the provider persists through the injected
/// sync-state store (ADR-0023/0024). All values are key/value only.
public enum CloudKitSyncStateKeys {
    /// Per-document open-clientID drain set `{clientID: fromClock}` (ADR-0024).
    public static let drainSet = "cloudkit.drainSet"

    /// Per-document queue of fetched changes waiting for that document's
    /// provider to register (ADR-0025).
    public static let inboundSpool = "cloudkit.inboundSpool"

    /// Per-document set of record names the store believes exist in its zone,
    /// which drives per-document removal (ADR-0025).
    public static let knownRecords = "cloudkit.knownRecords"

    /// Reserved document name for store-level (single-engine) state.
    public static let storeNamespace = "__swiftyrs_cloudkit_store__"
    /// The `CKSyncEngine.State.Serialization`; losing it forces a cold re-fetch.
    public static let engineState = "cloudkit.engineState"
    /// Every document name the store has recorded state for, so zone-wide
    /// removal can find it all.
    public static let knownDocuments = "cloudkit.knownDocuments"
}
