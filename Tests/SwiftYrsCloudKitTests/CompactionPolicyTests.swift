import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import Testing

@Test
func clientClockMapDecodesLib0StateVector() throws {
    // count=2, (client=1, clock=0), (client=2, clock=3) — the merged two-writer doc.
    let bytes = try #require(Data(base64Encoded: "AgEAAgM="))
    let map = try ClientClockMap(decoding: YStateVector(bytes))

    #expect(map.clocks == [1: 0, 2: 3])
    #expect(map.clock(for: 2) == 3)
    #expect(map.clock(for: 99) == 0)
}

@Test
func clientClockMapRejectsTrailingBytes() {
    let malformed = YStateVector(Data([0x01, 0x01, 0x00, 0xFF]))
    #expect(throws: CompactionPolicyError.malformedStateVector) {
        _ = try ClientClockMap(decoding: malformed)
    }
}

@Test
func shouldCompactCrossesCountAndByteThresholds() {
    let policy = CompactionPolicy(
        incrementalCountThreshold: 10,
        incrementalByteThreshold: 1_000,
        jitterFraction: 0
    )

    #expect(policy.shouldCompact(incrementalCount: 9, incrementalBytes: 0) == false)
    #expect(policy.shouldCompact(incrementalCount: 10, incrementalBytes: 0) == true)
    #expect(policy.shouldCompact(incrementalCount: 0, incrementalBytes: 999) == false)
    #expect(policy.shouldCompact(incrementalCount: 0, incrementalBytes: 1_000) == true)
}

@Test
func jitterStaggersTheEffectiveThreshold() {
    let policy = CompactionPolicy(
        incrementalCountThreshold: 10,
        incrementalByteThreshold: .max,
        jitterFraction: 0.5
    )

    // At threshold, a device with no jitter compacts; a fully-jittered device
    // (effective threshold 15) holds off — staggering the herd.
    #expect(policy.shouldCompact(incrementalCount: 10, incrementalBytes: 0, jitter: 0) == true)
    #expect(policy.shouldCompact(incrementalCount: 10, incrementalBytes: 0, jitter: 1) == false)
    #expect(policy.shouldCompact(incrementalCount: 15, incrementalBytes: 0, jitter: 1) == true)
}

@Test
func subsumedSelectionDeletesOnlyFullyCoveredIncrementals() throws {
    let policy = CompactionPolicy()
    let snapshot = ConfirmedSnapshot(confirmedSaved: ClientClockMap(clocks: [1: 5, 2: 3]))

    let incrementals = [
        IncrementalSummary(clientID: 1, fromClock: 0, toClock: 5, byteCount: 10), // covered
        IncrementalSummary(clientID: 2, fromClock: 0, toClock: 3, byteCount: 10), // covered
        IncrementalSummary(clientID: 1, fromClock: 5, toClock: 8, byteCount: 10), // after snapshot
        IncrementalSummary(clientID: 3, fromClock: 0, toClock: 2, byteCount: 10), // unknown writer
    ]

    let subsumed = policy.subsumedIncrementals(incrementals, by: snapshot)
    #expect(subsumed.map(\.clientID) == [1, 2])
    #expect(subsumed.map(\.toClock) == [5, 3])
}

@Test
func retainedSelectionKeepsConcurrentAndPostSnapshotEdits() throws {
    let policy = CompactionPolicy()
    let snapshot = ConfirmedSnapshot(confirmedSaved: ClientClockMap(clocks: [1: 5, 2: 3]))

    let incrementals = [
        IncrementalSummary(clientID: 1, fromClock: 0, toClock: 5, byteCount: 10), // covered → dropped
        IncrementalSummary(clientID: 1, fromClock: 5, toClock: 8, byteCount: 10), // after snapshot
        IncrementalSummary(clientID: 3, fromClock: 0, toClock: 2, byteCount: 10), // unknown writer
    ]

    let retained = policy.retainedIncrementals(incrementals, by: snapshot)
    #expect(retained.map(\.clientID) == [1, 3])
    #expect(Set(retained).isDisjoint(with: Set(policy.subsumedIncrementals(incrementals, by: snapshot))))
}

@Test
func confirmedSnapshotDecodesFromStateVectorBytes() throws {
    let bytes = try #require(Data(base64Encoded: "AgEAAgM="))
    let snapshot = try ConfirmedSnapshot(confirmedSaved: YStateVector(bytes))
    #expect(snapshot.stateVector.clock(for: 2) == 3)
}

@Test
func recheckSkipsCompactionWhenAnotherDeviceAlreadyCompacted() {
    let policy = CompactionPolicy(
        incrementalCountThreshold: 3,
        incrementalByteThreshold: .max,
        jitterFraction: 0
    )

    let incrementals = (0..<4).map { i in
        IncrementalSummary(clientID: UInt64(i + 1), fromClock: 0, toClock: 1, byteCount: 10)
    }

    // Before fetch: 4 incrementals over the threshold of 3 → attempt.
    #expect(policy.shouldCompact(incrementalCount: incrementals.count, incrementalBytes: 0) == true)

    // After fetch: the freshly-pulled snapshot already subsumes 3 of the 4
    // (another device compacted). Only one remains → skip the redundant work.
    let latest = ConfirmedSnapshot(confirmedSaved: ClientClockMap(clocks: [1: 1, 2: 1, 3: 1]))
    #expect(policy.shouldProceedAfterFetch(incrementals: incrementals, latestSnapshot: latest) == false)

    // If the snapshot still leaves the backlog over threshold, proceed.
    let stale = ConfirmedSnapshot(confirmedSaved: ClientClockMap(clocks: [:]))
    #expect(policy.shouldProceedAfterFetch(incrementals: incrementals, latestSnapshot: stale) == true)
}
