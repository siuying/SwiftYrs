import Foundation
import YrsBridgeFFI

private final class ObservationCallbackBox {
    let callback: (YEvent) -> Void

    init(callback: @escaping (YEvent) -> Void) {
        self.callback = callback
    }
}

// Native delivery can retain a callback after its subscription is removed.
// Monotonic opaque tokens let such callbacks safely miss the registry instead
// of dereferencing a released Swift context or a reused allocation address.
private final class ObservationCallbacks: @unchecked Sendable {
    static let shared = ObservationCallbacks()
    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var callbacks: [UInt: ObservationCallbackBox] = [:]

    func insert(_ callback: @escaping (YEvent) -> Void) -> UnsafeMutableRawPointer {
        lock.withLock {
            precondition(nextToken < UInt.max)
            let token = nextToken
            nextToken += 1
            callbacks[token] = ObservationCallbackBox(callback: callback)
            return UnsafeMutableRawPointer(bitPattern: token)!
        }
    }

    func lookup(_ context: UnsafeMutableRawPointer) -> ObservationCallbackBox? {
        lock.withLock { callbacks[UInt(bitPattern: context)] }
    }

    func remove(_ context: UnsafeMutableRawPointer) {
        // Release captured objects outside the registry lock; their deinitializers
        // may cancel other observations.
        let removed = lock.withLock { callbacks.removeValue(forKey: UInt(bitPattern: context)) }
        withExtendedLifetime(removed) {}
    }
}

private let observationCallback: YrsBridgeEventCallback = { context, data, length in
    guard let context else {
        return
    }
    guard let box = ObservationCallbacks.shared.lookup(context) else { return }
    box.callback(YEvent(data: Data(bytes: data, count: Int(length))))
}

public final class Observation: @unchecked Sendable {
    private var handle: OpaquePointer?
    private var context: UnsafeMutableRawPointer?
    // Releasing callback captures can re-enter cancel() on this observation.
    private let cancellationLock = NSRecursiveLock()
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
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        guard let handle else {
            return
        }
        self.handle = nil
        let context = self.context
        self.context = nil
        if let context { ObservationCallbacks.shared.remove(context) }
        yrs_bridge_observation_destroy(handle)
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
    let context = ObservationCallbacks.shared.insert(callback)
    guard let observationHandle = observe(handle, context, observationCallback) else {
        ObservationCallbacks.shared.remove(context)
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
