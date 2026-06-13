import Foundation
import YrsBridgeFFI

public struct YObservationEvent: @unchecked Sendable {
    public let kind: String
    public let data: Data
    public let object: [String: Any]

    init(data: Data) {
        self.data = data
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        self.object = object
        self.kind = object["kind"] as? String ?? ""
    }

    public func array(_ key: String) -> [Any] {
        object[key] as? [Any] ?? []
    }

    public func dictionary(_ key: String) -> [String: Any] {
        object[key] as? [String: Any] ?? [:]
    }

    /// The document update carried by a `YDoc.observeUpdates` event as a typed
    /// payload (ADR-0017), so callers never parse the raw event JSON. `nil` for
    /// any other event kind.
    public var updateV1: YUpdate? {
        guard kind == "updateV1" else {
            return nil
        }
        let bytes = array("updateV1").compactMap { value -> UInt8? in
            (value as? UInt8) ?? (value as? NSNumber)?.uint8Value
        }
        guard !bytes.isEmpty else {
            return nil
        }
        return .v1(Data(bytes))
    }

    /// Client IDs added, updated, or removed by a `YAwareness` update/change
    /// event. Empty for non-awareness events.
    public var changedAwarenessClientIDs: [UInt64] {
        (array("added") + array("updated") + array("removed")).compactMap { value in
            (value as? UInt64) ?? (value as? NSNumber)?.uint64Value
        }
    }
}

private final class ObservationCallbackBox {
    let callback: (YObservationEvent) -> Void

    init(callback: @escaping (YObservationEvent) -> Void) {
        self.callback = callback
    }
}

private let observationCallback: YrsBridgeEventCallback = { context, data, length in
    guard let context else {
        return
    }
    let box = Unmanaged<ObservationCallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.callback(YObservationEvent(data: Data(bytes: data, count: Int(length))))
}

public final class Observation: @unchecked Sendable {
    private var handle: OpaquePointer?
    private var context: UnsafeMutableRawPointer?

    init(handle: OpaquePointer, context: UnsafeMutableRawPointer) {
        self.handle = handle
        self.context = context
    }

    public func cancel() {
        guard let handle else {
            return
        }
        yrs_bridge_observation_destroy(handle)
        self.handle = nil
        if let context {
            Unmanaged<ObservationCallbackBox>.fromOpaque(context).release()
            self.context = nil
        }
    }

    deinit {
        cancel()
    }
}

private final class ObservationStreamState: @unchecked Sendable {
    var observation: Observation?
}

func makeObservation(
    _ callback: @escaping (YObservationEvent) -> Void,
    start: (UnsafeMutableRawPointer, YrsBridgeEventCallback) -> OpaquePointer?
) throws -> Observation {
    let box = ObservationCallbackBox(callback: callback)
    let context = Unmanaged.passRetained(box).toOpaque()
    guard let handle = start(context, observationCallback) else {
        Unmanaged<ObservationCallbackBox>.fromOpaque(context).release()
        throw YError.nullPointer
    }
    return Observation(handle: handle, context: context)
}

func makeEventStream(observe: (@escaping (YObservationEvent) -> Void) throws -> Observation) throws -> AsyncStream<YObservationEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: YObservationEvent.self)
    let state = ObservationStreamState()
    state.observation = try observe { event in
        continuation.yield(event)
    }
    continuation.onTermination = { _ in
        state.observation?.cancel()
        state.observation = nil
    }
    return stream
}

extension YDoc {
    public func observeUpdates(_ callback: @escaping (YObservationEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_doc_observe_update_v1(handle, context, callback)
        }
    }

    public func observeSubdocs(_ callback: @escaping (YObservationEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_doc_observe_subdocs(handle, context, callback)
        }
    }

    public func observeTransactionCleanup(_ callback: @escaping (YObservationEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_doc_observe_transaction_cleanup(handle, context, callback)
        }
    }

    public func observeDestroy(_ callback: @escaping (YObservationEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_doc_observe_destroy(handle, context, callback)
        }
    }

    public func updateEvents() throws -> AsyncStream<YObservationEvent> {
        try makeEventStream(observe: observeUpdates)
    }
}

// Shared types (`YText`, `YMap`, `YArray`, XML nodes, weak links) inherit
// `observe`/`events` from `YSharedType`.
