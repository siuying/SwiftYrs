import Foundation
import YrsBridgeFFI

private final class ObservationCallbackBox {
    let callback: (YEvent) -> Void

    init(callback: @escaping (YEvent) -> Void) {
        self.callback = callback
    }
}

private let observationCallback: YrsBridgeEventCallback = { context, data, length in
    guard let context else {
        return
    }
    let box = Unmanaged<ObservationCallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.callback(YEvent(data: Data(bytes: data, count: Int(length))))
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
    _ callback: @escaping (YEvent) -> Void,
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

func makeEventStream(observe: (@escaping (YEvent) -> Void) throws -> Observation) throws -> AsyncStream<YEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: YEvent.self)
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
    public func observeUpdates(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_doc_observe_update_v1(handle, context, callback)
        }
    }

    public func observeSubdocs(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_doc_observe_subdocs(handle, context, callback)
        }
    }

    public func observeTransactionCleanup(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_doc_observe_transaction_cleanup(handle, context, callback)
        }
    }

    public func observeDestroy(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_doc_observe_destroy(handle, context, callback)
        }
    }

    public func updateEvents() throws -> AsyncStream<YEvent> {
        try makeEventStream(observe: observeUpdates)
    }
}

// Shared types (`YText`, `YMap`, `YArray`, XML nodes, weak links) inherit
// `observe`/`events` from `YSharedType`.
