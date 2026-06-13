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

/// Awareness wraps a native handle; like `YDoc` it is `@unchecked Sendable` on
/// the contract that access is confined to one actor or serial queue. Declared
/// in core so transports share the contract.
extension YAwareness: @unchecked Sendable {}

public final class YAwareness {
    private let document: YDoc
    let handle: OpaquePointer

    public init(document: YDoc) {
        guard let handle = yrs_bridge_awareness_new(document.handle) else {
            preconditionFailure("YrsBridge failed to create awareness")
        }
        self.document = document
        self.handle = handle
    }

    deinit {
        yrs_bridge_awareness_destroy(handle)
    }

    public var clientID: UInt64 {
        yrs_bridge_awareness_client_id(handle)
    }

    public func setLocalState(_ state: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: state)
        try setLocalStateJSON(data)
    }

    public func setLocalStateJSON(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw YError.decodeFailure
            }
            let json = String(decoding: UnsafeRawBufferPointer(start: baseAddress, count: bytes.count), as: UTF8.self)
            try json.withCString { pointer in
                try throwIfNeeded(yrs_bridge_awareness_set_local_state_json(handle, pointer))
            }
        }
    }

    public func clearLocalState() {
        yrs_bridge_awareness_clear_local_state(handle)
    }

    public func removeState(for clientID: UInt64) {
        yrs_bridge_awareness_remove_state(handle, clientID)
    }

    public func localState() throws -> Any? {
        try jsonBuffer(yrs_bridge_awareness_local_state_json)
    }

    public func state(for clientID: UInt64) throws -> Any? {
        let data = try readingBuffer { yrs_bridge_awareness_state_json(handle, clientID, &$0) }
        return try decodeOptionalJSON(from: data)
    }

    public func states() throws -> [YAwarenessClientState] {
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
        try YAwarenessUpdate(readingBuffer { yrs_bridge_awareness_encode_update(handle, &$0) })
    }

    public func encodeUpdate(for clientIDs: [UInt64]) throws -> YAwarenessUpdate {
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
        try update.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw YError.decodeFailure
            }
            try throwIfNeeded(yrs_bridge_awareness_apply_update(
                handle,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(bytes.count)
            ))
        }
    }

    public func observeUpdate(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_awareness_observe_update(handle, context, callback)
        }
    }

    public func observeChange(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_awareness_observe_change(handle, context, callback)
        }
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
