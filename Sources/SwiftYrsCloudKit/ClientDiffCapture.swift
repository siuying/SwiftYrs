import Foundation
import SwiftYrs

public struct ClientDiffCapture: Sendable {
    public init() {}

    public func currentClock(in doc: YDoc, clientID: UInt64) throws -> UInt32 {
        try doc.clientClock(clientID: clientID)
    }

    public func clientDiff(
        in doc: YDoc,
        clientID: UInt64,
        fromClock: UInt32,
        encoding: YUpdate.Encoding = .v1
    ) throws -> YUpdate? {
        let currentClock = try currentClock(in: doc, clientID: clientID)
        guard currentClock > fromClock else {
            return nil
        }

        switch encoding {
        case .v1:
            return try doc.encodeClientStateAsUpdateV1(clientID: clientID, fromClock: fromClock)
        case .v2:
            return try doc.encodeClientStateAsUpdateV2(clientID: clientID, fromClock: fromClock)
        }
    }
}
