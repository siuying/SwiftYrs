import Foundation
import SwiftYrs

public enum CompactionPolicyError: Error, Equatable {
    case malformedStateVector
}

/// A lib0 state vector decoded into per-client logical clocks.
///
/// The snapshot record stores its state vector as opaque bytes; compaction and
/// GC need to read it as `{ clientID: clock }` to decide which incrementals are
/// already subsumed. The decode mirrors lib0's encoding: a `varUint` client
/// count followed by `(client, clock)` `varUint` pairs.
public struct ClientClockMap: Equatable, Sendable {
    public let clocks: [UInt64: UInt32]

    public init(clocks: [UInt64: UInt32] = [:]) {
        self.clocks = clocks
    }

    public init(decoding stateVector: YStateVector) throws {
        let bytes = [UInt8](stateVector.data)
        var index = 0

        func readVarUint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.count else {
                    throw CompactionPolicyError.malformedStateVector
                }
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    return result
                }
                shift += 7
                guard shift < 64 else {
                    throw CompactionPolicyError.malformedStateVector
                }
            }
        }

        let count = try readVarUint()
        var clocks: [UInt64: UInt32] = [:]
        for _ in 0..<count {
            let client = try readVarUint()
            let clock = try readVarUint()
            guard clock <= UInt64(UInt32.max) else {
                throw CompactionPolicyError.malformedStateVector
            }
            clocks[client] = UInt32(clock)
        }
        guard index == bytes.count else {
            throw CompactionPolicyError.malformedStateVector
        }
        self.clocks = clocks
    }

    /// The clock the snapshot holds for `clientID`; `0` for an unknown client,
    /// which correctly retains any incremental that client authored.
    public func clock(for clientID: UInt64) -> UInt32 {
        clocks[clientID] ?? 0
    }
}

/// The compaction-relevant shape of one per-writer incremental record.
public struct IncrementalSummary: Hashable, Sendable {
    public let clientID: UInt64
    public let fromClock: UInt32
    public let toClock: UInt32
    public let byteCount: Int

    public init(clientID: UInt64, fromClock: UInt32, toClock: UInt32, byteCount: Int) {
        self.clientID = clientID
        self.fromClock = fromClock
        self.toClock = toClock
        self.byteCount = byteCount
    }
}

/// Proof that a snapshot's state vector has been *confirmed saved* to CloudKit.
///
/// GC may delete a subsumed incremental only after the snapshot that subsumes
/// it is durably stored (ADR-0023). Making the confirmed state vector the only
/// way to ask for the delete set turns that precondition into something the
/// type system enforces — there is no way to compute deletions from an
/// unconfirmed snapshot.
public struct ConfirmedSnapshot: Equatable, Sendable {
    public let stateVector: ClientClockMap

    public init(confirmedSaved stateVector: ClientClockMap) {
        self.stateVector = stateVector
    }

    public init(confirmedSaved stateVector: YStateVector) throws {
        self.stateVector = try ClientClockMap(decoding: stateVector)
    }
}

/// Pure compaction and GC decisions (ADR-0023/0024). Holds no CloudKit state;
/// every method is a deterministic function of its inputs so the herd-damping
/// and subsumption rules are unit-testable without iCloud.
public struct CompactionPolicy: Sendable {
    public static let defaultIncrementalCountThreshold = 64
    public static let defaultIncrementalByteThreshold = 512 * 1024
    public static let defaultJitterFraction = 0.25

    public let incrementalCountThreshold: Int
    public let incrementalByteThreshold: Int
    public let jitterFraction: Double

    public init(
        incrementalCountThreshold: Int = defaultIncrementalCountThreshold,
        incrementalByteThreshold: Int = defaultIncrementalByteThreshold,
        jitterFraction: Double = defaultJitterFraction
    ) {
        self.incrementalCountThreshold = incrementalCountThreshold
        self.incrementalByteThreshold = incrementalByteThreshold
        self.jitterFraction = jitterFraction
    }

    /// Whether compaction should be attempted given the current incremental
    /// backlog. `jitter` is a caller-supplied value in `0...1` (random per
    /// attempt) that scales the thresholds up, so devices crossing the limit at
    /// the same moment pick slightly different effective thresholds and do not
    /// all stampede into a compaction at once.
    public func shouldCompact(incrementalCount: Int, incrementalBytes: Int, jitter: Double = 0) -> Bool {
        let clampedJitter = min(max(jitter, 0), 1)
        let scale = 1 + max(jitterFraction, 0) * clampedJitter
        let countLimit = Double(incrementalCountThreshold) * scale
        let byteLimit = Double(incrementalByteThreshold) * scale
        return Double(incrementalCount) >= countLimit || Double(incrementalBytes) >= byteLimit
    }

    /// Incrementals whose every op is already in the confirmed snapshot, hence
    /// safe to delete: the snapshot's clock for the writer is at least the
    /// incremental's `toClock`.
    public func subsumedIncrementals(
        _ incrementals: [IncrementalSummary],
        by snapshot: ConfirmedSnapshot
    ) -> [IncrementalSummary] {
        incrementals.filter { snapshot.stateVector.clock(for: $0.clientID) >= $0.toClock }
    }

    /// Incrementals the snapshot does not fully cover and must be kept — those
    /// authored after the snapshot, or by a writer the snapshot never saw
    /// (concurrent edits). Complement of ``subsumedIncrementals(_:by:)``.
    public func retainedIncrementals(
        _ incrementals: [IncrementalSummary],
        by snapshot: ConfirmedSnapshot
    ) -> [IncrementalSummary] {
        incrementals.filter { snapshot.stateVector.clock(for: $0.clientID) < $0.toClock }
    }

    /// Post-fetch re-check (ADR-0024 herd damping). After deciding to compact,
    /// a device re-fetches the latest snapshot and calls this with it; the
    /// decision is recomputed over only the incrementals that snapshot does not
    /// yet subsume. If another device already compacted, the retained backlog
    /// has fallen below threshold and this returns `false`, so the trailing
    /// devices skip the redundant compaction.
    public func shouldProceedAfterFetch(
        incrementals: [IncrementalSummary],
        latestSnapshot: ConfirmedSnapshot,
        jitter: Double = 0
    ) -> Bool {
        let retained = retainedIncrementals(incrementals, by: latestSnapshot)
        let bytes = retained.reduce(0) { $0 + $1.byteCount }
        return shouldCompact(incrementalCount: retained.count, incrementalBytes: bytes, jitter: jitter)
    }
}
