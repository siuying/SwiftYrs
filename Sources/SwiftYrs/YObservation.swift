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
    private let synchronizationLock: NSRecursiveLock?
    private let onCancel: (() -> Void)?

    init(
        handle: OpaquePointer,
        context: UnsafeMutableRawPointer,
        synchronizationLock: NSRecursiveLock? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.handle = handle
        self.context = context
        self.synchronizationLock = synchronizationLock
        self.onCancel = onCancel
    }

    public func cancel() {
        synchronizationLock?.lock()
        defer { synchronizationLock?.unlock() }
        guard let handle else {
            return
        }
        yrs_bridge_observation_destroy(handle)
        self.handle = nil
        if let context {
            Unmanaged<ObservationCallbackBox>.fromOpaque(context).release()
            self.context = nil
        }
        onCancel?()
    }

    deinit {
        cancel()
    }
}

private final class ObservationStreamState: @unchecked Sendable {
    var observation: Observation?
}

typealias BridgeObserve = (OpaquePointer, UnsafeMutableRawPointer?, YrsBridgeEventCallback) -> OpaquePointer?

func registerObservation(
    handle: OpaquePointer,
    observe: BridgeObserve,
    synchronizationLock: NSRecursiveLock? = nil,
    onCancel: (() -> Void)? = nil,
    _ callback: @escaping (YEvent) -> Void
) throws -> Observation {
    let box = ObservationCallbackBox(callback: callback)
    let context = Unmanaged.passRetained(box).toOpaque()
    guard let observationHandle = observe(handle, context, observationCallback) else {
        Unmanaged<ObservationCallbackBox>.fromOpaque(context).release()
        throw YError.nullPointer
    }
    return Observation(handle: observationHandle, context: context, synchronizationLock: synchronizationLock, onCancel: onCancel)
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
        try registerObservation(handle: handle, observe: yrs_bridge_doc_observe_update_v1, callback)
    }

    public func observeSubdocs(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try registerObservation(handle: handle, observe: yrs_bridge_doc_observe_subdocs, callback)
    }

    public func observeTransactionCleanup(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try registerObservation(handle: handle, observe: yrs_bridge_doc_observe_transaction_cleanup, callback)
    }

    public func observeDestroy(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try registerObservation(handle: handle, observe: yrs_bridge_doc_observe_destroy, callback)
    }

    public func updateEvents() throws -> AsyncStream<YEvent> {
        try makeEventStream(observe: observeUpdates)
    }
}

// Shared types (`YText`, `YMap`, `YArray`, XML nodes, weak links) inherit
// `observe`/`events` from `YSharedType`.
