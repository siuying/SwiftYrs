#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftYrs

/// `YUpdate.Encoding` in a form that survives a relaunch.
enum InboundEncoding: String, Codable, Equatable, Sendable {
    case v1
    case v2

    init(_ encoding: YUpdate.Encoding) {
        switch encoding {
        case .v1: self = .v1
        case .v2: self = .v2
        }
    }

    var encoding: YUpdate.Encoding {
        switch self {
        case .v1: return .v1
        case .v2: return .v2
        }
    }
}

/// One remote change for one document, in the form the provider applies and the
/// spool persists.
///
/// The store decodes every fetched `CKRecord` into this once, at the callback
/// where any `CKAsset` file is still readable, and both the live path and the
/// replay path carry it from there. Passing `CKRecord`s instead would mean
/// decoding to bytes, re-encoding to a record (writing a fresh asset file
/// nothing deletes), and decoding again — three conversions of the same bytes.
enum InboundChange: Codable, Equatable, Sendable {
    case incremental(clientID: UInt64, fromClock: UInt32, toClock: UInt32, encoding: InboundEncoding, update: Data)
    case snapshot(encoding: InboundEncoding, update: Data, stateVector: Data)
    /// A record the server no longer holds. Deletions are GC of subsumed
    /// incrementals — their content already lives in the doc or a snapshot —
    /// so applying one changes nothing; it only lets the provider forget the
    /// record.
    case deletion(recordName: String)

    init(_ payload: CloudKitIncrementalRecordPayload) {
        self = .incremental(
            clientID: payload.clientID,
            fromClock: payload.fromClock,
            toClock: payload.toClock,
            encoding: InboundEncoding(payload.update.encoding),
            update: payload.update.data
        )
    }

    init(_ payload: CloudKitSnapshotRecordPayload) {
        self = .snapshot(
            encoding: InboundEncoding(payload.update.encoding),
            update: payload.update.data,
            stateVector: payload.stateVector.data
        )
    }
}

/// One spooled change with the sequence number that identifies it.
///
/// Replay applies a batch and only then removes it, so a crash mid-replay costs
/// nothing (yrs updates are idempotent and commutative). Removal is by sequence
/// rather than by position because a snapshot arriving during the replay may
/// coalesce entries away and shift every index.
struct SpooledChange: Codable, Equatable, Sendable {
    let sequence: UInt64
    let change: InboundChange
}

/// The persisted queue of fetched changes for one document.
struct SpooledChanges: Codable, Equatable, Sendable {
    var nextSequence: UInt64 = 0
    var changes: [SpooledChange] = []
}

/// Fetched changes waiting to be applied to a document, persisted per document
/// through ``CloudKitMetadataStore`` (ADR-0025).
///
/// `CKSyncEngine` fetches the store's zone whether or not a provider is
/// attached, and the change token advances either way, so a change that is not
/// durably held before the token moves is gone for good. With lazily-started
/// providers — a wiki app opening one page at a time — that would silently lose
/// remote edits. Every fetched change therefore lands here first and is applied
/// from here, which makes arrival order a property of the queue rather than of
/// the code that reads it.
///
/// Bounded by coalescing rather than a cap: dropping the oldest entry is wrong
/// for CRDT updates, so instead an arriving snapshot replaces any spooled
/// snapshot and drops every spooled incremental its state vector already
/// covers. A document that syncs often and is never opened therefore settles at
/// roughly one snapshot plus the changes authored after it.
struct InboundSpool: Sendable {
    private let persisted: PersistedValue<SpooledChanges>

    init(
        metadataStore: CloudKitMetadataStore,
        documentName: String,
        reportError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.persisted = PersistedValue(
            metadataStore: metadataStore,
            key: CloudKitSyncStateKeys.inboundSpool,
            documentName: documentName,
            empty: SpooledChanges(),
            reportError: reportError
        )
    }

    func append(_ additions: [InboundChange]) {
        guard !additions.isEmpty else { return }
        persisted.mutate { spool in
            for change in additions {
                spool.changes.append(SpooledChange(sequence: spool.nextSequence, change: change))
                spool.nextSequence += 1
            }
            spool.changes = Self.coalesced(spool.changes)
        }
    }

    /// Everything waiting, oldest first.
    func pending() -> [SpooledChange] {
        persisted.load().changes
    }

    /// Forget the changes that have been applied, keeping anything that arrived
    /// while they were being applied.
    func remove(throughSequence sequence: UInt64) {
        persisted.mutate { spool in
            spool.changes.removeAll { $0.sequence <= sequence }
        }
    }

    func clear() {
        persisted.clear()
    }

    /// Drop what the newest spooled snapshot already carries: any earlier
    /// snapshot, and every incremental whose `toClock` the snapshot's state
    /// vector covers. Everything else keeps its order.
    static func coalesced(_ changes: [SpooledChange]) -> [SpooledChange] {
        guard let newestSnapshotIndex = changes.lastIndex(where: {
            if case .snapshot = $0.change { return true }
            return false
        }) else {
            return changes
        }
        guard case let .snapshot(_, _, stateVectorData) = changes[newestSnapshotIndex].change,
              let clocks = try? ClientClockMap(decoding: YStateVector(stateVectorData))
        else {
            return changes
        }

        return changes.enumerated().compactMap { index, spooled in
            switch spooled.change {
            case .snapshot:
                return index == newestSnapshotIndex ? spooled : nil
            case let .incremental(clientID, _, toClock, _, _):
                return index < newestSnapshotIndex && toClock <= clocks.clock(for: clientID) ? nil : spooled
            case .deletion:
                return spooled
            }
        }
    }
}
#endif
