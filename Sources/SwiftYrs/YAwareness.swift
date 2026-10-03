import Foundation
import YrsBridgeFFI

public struct YAwarenessUpdate: Equatable, Sendable {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }
}

public struct YAwarenessClientState {
    public let clientID: UInt64
    public let state: Any
}

/// Awareness serializes native access and lifetime checks with a recursive lock.
/// User callbacks run serially outside the lock and may re-enter from any thread.
extension YAwareness: @unchecked Sendable {}

public final class YAwareness {
    public struct Timing: Sendable {
        public let checkInterval: Duration
        public let outdatedTimeout: Duration

        public init(checkInterval: Duration = .seconds(3), outdatedTimeout: Duration = .seconds(30)) {
            precondition(checkInterval > .zero && outdatedTimeout > .zero)
            self.checkInterval = checkInterval
            self.outdatedTimeout = outdatedTimeout
        }
    }

    public let timing: Timing
    let document: YDoc
    let handle: OpaquePointer
    private let now: @Sendable () -> Duration
    private let lock = NSRecursiveLock()
    private var lastUpdated: [UInt64: Duration] = [:]
    private var timestampObservation: Observation?
    private var eventOrigin: String?
    private var accessDepth = 0
    private var deliveringEvents = false
    private var pendingEvents: [() -> Void] = []

    public convenience init(document: YDoc) {
        self.init(document: document, timing: .init())
    }

    public init(
        document: YDoc,
        timing: Timing = .init(),
        now: (@Sendable () -> Duration)? = nil
    ) {
        guard let handle = yrs_bridge_awareness_new(document.handle) else {
            preconditionFailure("YrsBridge failed to create awareness")
        }
        self.document = document
        self.handle = handle
        self.timing = timing
        let start = ContinuousClock.now
        self.now = now ?? { start.duration(to: .now) }
        do {
            timestampObservation = try registerObservation(
                handle: handle, observe: yrs_bridge_awareness_observe_update, synchronizationLock: lock
            ) { [weak self] event in
                guard let self, case let .awarenessUpdate(change) = event else { return }
                let timestamp = self.now()
                for id in change.added + change.updated {
                    if self.hasState(for: id) {
                        self.lastUpdated[id] = timestamp
                    }
                }
                for id in change.removed {
                    if !self.hasState(for: id) {
                        self.lastUpdated.removeValue(forKey: id)
                    }
                }
            }
        } catch {
            preconditionFailure("YrsBridge failed to observe awareness")
        }
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        timestampObservation?.cancel()
        yrs_bridge_awareness_destroy(handle)
    }

    public var clientID: UInt64 {
        withAccess { yrs_bridge_awareness_client_id(handle) }
    }

    public func setLocalState(_ state: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: state)
        try setLocalStateJSON(data)
    }

    public func setLocalStateJSON(_ data: Data) throws {
        guard let json = String(data: data, encoding: .utf8) else {
            throw YError.decodeFailure
        }
        try withAccess {
            try json.withCString { pointer in
                try throwIfNeeded(yrs_bridge_awareness_set_local_state_json(handle, pointer))
            }
        }
    }

    public func clearLocalState() {
        withAccess { yrs_bridge_awareness_clear_local_state(handle) }
    }

    public func removeState(for clientID: UInt64) {
        withAccess { yrs_bridge_awareness_remove_state(handle, clientID) }
    }

    public func localState() throws -> Any? {
        try withAccess { try jsonBuffer(yrs_bridge_awareness_local_state_json) }
    }

    public func state(for clientID: UInt64) throws -> Any? {
        try withAccess {
            let data = try readingBuffer { yrs_bridge_awareness_state_json(handle, clientID, &$0) }
            return try decodeOptionalJSON(from: data)
        }
    }

    private func hasState(for clientID: UInt64) -> Bool {
        let data = try? readingBuffer { yrs_bridge_awareness_state_json(handle, clientID, &$0) }
        return data?.isEmpty == false
    }

    public func states() throws -> [YAwarenessClientState] {
        try withAccess { try readStates() }
    }

    private func readStates() throws -> [YAwarenessClientState] {
        let value = try jsonBuffer(yrs_bridge_awareness_states_json)
        guard let entries = value as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let clientID = entry["clientID"] as? UInt64 ?? (entry["clientID"] as? NSNumber)?.uint64Value,
                  let state = entry["state"] else {
                return nil
            }
            return YAwarenessClientState(clientID: clientID, state: state)
        }
    }

    public func encodeUpdate() throws -> YAwarenessUpdate {
        try withAccess { try YAwarenessUpdate(readingBuffer { yrs_bridge_awareness_encode_update(handle, &$0) }) }
    }

    public func encodeUpdate(for clientIDs: [UInt64]) throws -> YAwarenessUpdate {
        try withAccess { try encodeClientUpdate(for: clientIDs) }
    }

    private func encodeClientUpdate(for clientIDs: [UInt64]) throws -> YAwarenessUpdate {
        let data = try clientIDs.withUnsafeBufferPointer { clientIDs -> Data in
            guard let baseAddress = clientIDs.baseAddress else {
                throw YError.decodeFailure
            }
            return try readingBuffer {
                yrs_bridge_awareness_encode_update_for_clients(
                    handle,
                    baseAddress,
                    UInt(clientIDs.count),
                    &$0
                )
            }
        }
        return YAwarenessUpdate(data)
    }

    public func applyUpdate(_ update: YAwarenessUpdate) throws {
        try applyUpdate(update, origin: nil)
    }

    public func applyUpdate(_ update: YAwarenessUpdate, origin: String?) throws {
        try withAccess {
            let previousOrigin = eventOrigin
            eventOrigin = origin
            defer { eventOrigin = previousOrigin }
            try withUInt8Pointer(update.data) { pointer, length in
                try throwIfNeeded(yrs_bridge_awareness_apply_update(
                    handle,
                    pointer,
                    length
                ))
            }
        }
    }

    func withAccess<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        accessDepth += 1
        defer {
            accessDepth -= 1
            let shouldDeliver = accessDepth == 0 && !deliveringEvents && !pendingEvents.isEmpty
            if shouldDeliver { deliveringEvents = true }
            lock.unlock()
            if shouldDeliver { deliverEvents() }
        }
        return try body()
    }

    private func deliverEvents() {
        while true {
            let events = lock.withLock {
                let events = pendingEvents
                pendingEvents.removeAll(keepingCapacity: true)
                if events.isEmpty { deliveringEvents = false }
                return events
            }
            guard !events.isEmpty else { return }
            for event in events { event() }
        }
    }

    /// Delivers updates serially outside the awareness lock. Nested events are
    /// breadth-first, unlike JavaScript's depth-first delivery. State updates happen immediately,
    /// but delivery may be delayed or run on another thread; callbacks should read current state.
    public func observeUpdate(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try observe(yrs_bridge_awareness_observe_update, callback)
    }

    /// Delivers changes serially outside the awareness lock. Nested events are
    /// breadth-first, unlike JavaScript's depth-first delivery. State updates happen immediately,
    /// but delivery may be delayed or run on another thread; callbacks should read current state.
    public func observeChange(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try observe(yrs_bridge_awareness_observe_change, callback)
    }

    /// Connection providers schedule checks while connected and stop on teardown.
    public func checkTimeouts() throws {
        try withAccess { try maintainLifetime() }
    }

    private func maintainLifetime() throws {
        let timestamp = now()
        if let updated = lastUpdated[clientID],
           timestamp - updated >= timing.outdatedTimeout / 2 {
            let data = try readingBuffer { yrs_bridge_awareness_local_state_json(handle, &$0) }
            if !data.isEmpty, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) != "null" {
                try setLocalStateJSON(data)
            }
        }
        let expired = lastUpdated.compactMap { id, updated in
            id != clientID && timestamp - updated >= timing.outdatedTimeout ? id : nil
        }.sorted()
        guard !expired.isEmpty else { return }

        // Yjs timeout removals retain remote clocks, so a peer's next renewal wins.
        let update = try encodeUpdate(for: expired).removingStates()
        try applyUpdate(update, origin: YAwarenessChange.timeoutOrigin)
    }

    private func observe(_ operation: BridgeObserve, _ callback: @escaping (YEvent) -> Void) throws -> Observation {
        let delivery = AwarenessEventDelivery(callback)
        return try withAccess {
            try registerObservation(
                handle: handle, observe: operation, synchronizationLock: lock, onCancel: delivery.cancel
            ) { [weak self] event in
                guard let self else { return }
                let delivered: YEvent
                switch event {
                case let .awarenessUpdate(change):
                    delivered = .awarenessUpdate(self.withOrigin(change, origin: self.eventOrigin))
                case let .awarenessChange(change):
                    delivered = .awarenessChange(self.withOrigin(change, origin: self.eventOrigin))
                default:
                    delivered = event
                }
                self.pendingEvents.append { delivery.deliver(delivered) }
            }
        }
    }

    private func withOrigin(_ change: YAwarenessChange, origin: String?) -> YAwarenessChange {
        YAwarenessChange(added: change.added, updated: change.updated, removed: change.removed, origin: origin)
    }

    public func updateEvents() throws -> AsyncStream<YEvent> {
        try makeEventStream(observe: observeUpdate)
    }

    public func changeEvents() throws -> AsyncStream<YEvent> {
        try makeEventStream(observe: observeChange)
    }

    private func jsonBuffer(_ operation: (OpaquePointer, UnsafeMutablePointer<YrsBridgeBuffer>) -> Int32) throws -> Any? {
        let data = try readingBuffer { operation(handle, &$0) }
        return try decodeOptionalJSON(from: data)
    }

    private func decodeOptionalJSON(from data: Data) throws -> Any? {
        if data.isEmpty {
            return nil
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}

private final class AwarenessEventDelivery {
    private let lock = NSLock()
    private var callback: ((YEvent) -> Void)?

    init(_ callback: @escaping (YEvent) -> Void) {
        self.callback = callback
    }

    func cancel() {
        lock.withLock { callback = nil }
    }

    func deliver(_ event: YEvent) {
        let callback = lock.withLock { self.callback }
        callback?(event)
    }
}

private extension YAwarenessUpdate {
    func removingStates() throws -> YAwarenessUpdate {
        var result = Data()
        let prefix = try visitEntries { _, _, header in
            result.append(contentsOf: header)
            result.append(4)
            result.append(contentsOf: "null".utf8)
        }
        return YAwarenessUpdate(Data(prefix) + result)
    }

    func visitEntries(_ visit: (UInt64, UInt64, ArraySlice<UInt8>) -> Void) throws -> ArraySlice<UInt8> {
        let bytes = [UInt8](data)
        var offset = 0
        func readVarUint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift = 0
            while offset < bytes.count && shift < 64 {
                let byte = bytes[offset]
                offset += 1
                guard shift < 63 || byte < 2 else { throw YError.decodeFailure }
                value |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            throw YError.decodeFailure
        }
        let count = try readVarUint()
        let prefix = bytes[..<offset]
        for _ in 0..<count {
            let start = offset
            let id = try readVarUint()
            let clock = try readVarUint()
            let header = bytes[start..<offset]
            let length = try readVarUint()
            guard length <= bytes.count - offset else { throw YError.decodeFailure }
            offset += Int(length)
            visit(id, clock, header)
        }
        return prefix
    }
}
