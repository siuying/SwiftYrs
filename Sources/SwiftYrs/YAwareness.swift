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
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_awareness_state_json(handle, clientID, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        return try decodeOptionalJSON(from: buffer)
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
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_awareness_encode_update(handle, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        return YAwarenessUpdate(data(from: buffer))
    }

    public func encodeUpdate(for clientIDs: [UInt64]) throws -> YAwarenessUpdate {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try clientIDs.withUnsafeBufferPointer { clientIDs in
            guard let baseAddress = clientIDs.baseAddress else {
                throw YError.decodeFailure
            }
            try throwIfNeeded(yrs_bridge_awareness_encode_update_for_clients(
                handle,
                baseAddress,
                UInt(clientIDs.count),
                &buffer
            ))
        }
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        return YAwarenessUpdate(data(from: buffer))
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

    public func observeUpdate(_ callback: @escaping (YObservationEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_awareness_observe_update(handle, context, callback)
        }
    }

    public func observeChange(_ callback: @escaping (YObservationEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_awareness_observe_change(handle, context, callback)
        }
    }

    public func updateEvents() throws -> AsyncStream<YObservationEvent> {
        try makeEventStream(observe: observeUpdate)
    }

    public func changeEvents() throws -> AsyncStream<YObservationEvent> {
        try makeEventStream(observe: observeChange)
    }

    private func jsonBuffer(_ operation: (OpaquePointer, UnsafeMutablePointer<YrsBridgeBuffer>) -> Int32) throws -> Any? {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(operation(handle, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        return try decodeOptionalJSON(from: buffer)
    }

    private func decodeOptionalJSON(from buffer: YrsBridgeBuffer) throws -> Any? {
        let data = data(from: buffer)
        if data.isEmpty {
            return nil
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}
