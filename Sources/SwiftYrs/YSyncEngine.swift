import Foundation

public struct YSyncEngineResult: Equatable, Sendable {
    public let didSync: Bool
    public let awarenessAddedClientIDs: Set<UInt64>
    public let awarenessRemovedClientIDs: Set<UInt64>

    public init(
        didSync: Bool = false,
        awarenessAddedClientIDs: Set<UInt64> = [],
        awarenessRemovedClientIDs: Set<UInt64> = []
    ) {
        self.didSync = didSync
        self.awarenessAddedClientIDs = awarenessAddedClientIDs
        self.awarenessRemovedClientIDs = awarenessRemovedClientIDs
    }
}

public struct YSyncEngine {
    private let doc: YDoc
    private let awareness: YAwareness?
    private let send: (YSyncMessage) throws -> Void
    private let applyUpdate: (YUpdate) throws -> Void
    private let applyAwarenessUpdate: (YAwarenessUpdate) throws -> Void

    public init(
        doc: YDoc,
        awareness: YAwareness?,
        send: @escaping (YSyncMessage) throws -> Void,
        applyUpdate: ((YUpdate) throws -> Void)? = nil,
        applyAwarenessUpdate: ((YAwarenessUpdate) throws -> Void)? = nil
    ) {
        self.doc = doc
        self.awareness = awareness
        self.send = send
        self.applyUpdate = applyUpdate ?? { update in
            try doc.apply(update)
        }
        self.applyAwarenessUpdate = applyAwarenessUpdate ?? { update in
            try awareness?.applyUpdate(update)
        }
    }

    @discardableResult
    public func initialSync(
        includeAwarenessQuery: Bool = true,
        includeKnownAwarenessStates: Bool = true
    ) throws -> [YSyncMessage] {
        var messages = [try YSyncMessage.syncStep1(doc.stateVector())]
        if includeAwarenessQuery {
            messages.append(try YSyncMessage.awarenessQuery())
        }
        if includeKnownAwarenessStates, let knownStates = try knownAwarenessStatesMessage() {
            messages.append(knownStates)
        }
        try messages.forEach(send)
        return messages
    }

    @discardableResult
    public func handle(_ message: YSyncMessage) throws -> YSyncEngineResult {
        switch message {
        case let .syncStep1(stateVector, _):
            let update = try doc.encodeStateAsUpdateV1(from: stateVector)
            try send(.syncStep2(update))
            return YSyncEngineResult()
        case let .syncStep2(update, _):
            try applyUpdate(update)
            return YSyncEngineResult(didSync: true)
        case let .update(update, _):
            try applyUpdate(update)
            return YSyncEngineResult()
        case let .awareness(update, _):
            return try applyAwareness(update)
        case .awarenessQuery:
            try sendKnownAwarenessStates()
            return YSyncEngineResult()
        default:
            return YSyncEngineResult()
        }
    }

    public func sendKnownAwarenessStates() throws {
        guard let message = try knownAwarenessStatesMessage() else {
            return
        }
        try send(message)
    }

    private func applyAwareness(_ update: YAwarenessUpdate) throws -> YSyncEngineResult {
        guard let awareness else {
            return YSyncEngineResult()
        }

        let before = try Set(awareness.states().map(\.clientID))
        try applyAwarenessUpdate(update)
        let after = try Set(awareness.states().map(\.clientID))
        return YSyncEngineResult(
            awarenessAddedClientIDs: after.subtracting(before).filter { $0 != awareness.clientID },
            awarenessRemovedClientIDs: before.subtracting(after)
        )
    }

    private func knownAwarenessStatesMessage() throws -> YSyncMessage? {
        guard let awareness else {
            return nil
        }
        let clientIDs = try awareness.states().map(\.clientID)
        guard !clientIDs.isEmpty else {
            return nil
        }
        return try .awareness(awareness.encodeUpdate(for: clientIDs))
    }
}
