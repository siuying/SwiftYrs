import Foundation
import SwiftYrs

/// One writer session's un-confirmed edits to re-ship on launch.
public struct RecoveryResend: Equatable, Sendable {
    public let clientID: UInt64
    public let fromClock: UInt32
    public let update: YUpdate

    public init(clientID: UInt64, fromClock: UInt32, update: YUpdate) {
        self.clientID = clientID
        self.fromClock = fromClock
        self.update = update
    }
}

/// The outcome of draining the open-client set on launch: the diffs to re-send
/// and the clientIDs that can be retired because they have nothing outstanding.
public struct RecoveryPlan: Equatable, Sendable {
    public let resends: [RecoveryResend]
    public let retired: [UInt64]

    public init(resends: [RecoveryResend], retired: [UInt64]) {
        self.resends = resends
        self.retired = retired
    }
}

/// Pure recovery logic (ADR-0024). The provider persists `{clientID: fromClock}`
/// for every writer session whose authored edits are not yet confirmed uploaded
/// — normally 0–1 entries, but more under chained crashes. On launch this
/// re-derives each session's outstanding client-scoped diff from the persisted
/// doc, so un-uploaded edits eventually propagate without any durable outbox.
public struct RecoveryPlanner: Sendable {
    private let capture: ClientDiffCapture

    public init(capture: ClientDiffCapture = ClientDiffCapture()) {
        self.capture = capture
    }

    /// For each open client, the client-scoped diff since its marker clock. A
    /// client whose diff is empty — its clock has not advanced past the marker,
    /// including a client that authored nothing in this doc — is retired rather
    /// than re-sent. Output is ordered by clientID for determinism.
    public func plan(
        openClients: [UInt64: UInt32],
        in doc: YDoc,
        encoding: YUpdate.Encoding = .v1
    ) throws -> RecoveryPlan {
        var resends: [RecoveryResend] = []
        var retired: [UInt64] = []

        for clientID in openClients.keys.sorted() {
            let fromClock = openClients[clientID]!
            if let update = try capture.clientDiff(
                in: doc,
                clientID: clientID,
                fromClock: fromClock,
                encoding: encoding
            ) {
                resends.append(
                    RecoveryResend(clientID: clientID, fromClock: fromClock, update: update)
                )
            } else {
                retired.append(clientID)
            }
        }

        return RecoveryPlan(resends: resends, retired: retired)
    }
}
