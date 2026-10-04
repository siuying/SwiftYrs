import Foundation
import OSLog

private let logger = Logger(subsystem: "SwiftYrsHocuspocus", category: "outbound")

struct OutboundFrame: Sendable {
    enum Kind: Sendable, Equatable {
        case message
        /// Current awareness states for these clients. A newer frame replaces
        /// queued frames whose clients it covers.
        case awareness(Set<UInt64>)
    }

    let data: Data
    let kind: Kind
    var receipt: SendReceipt? = nil
}

/// Resolves once when its frame is written, discarded or fails to write.
final class SendReceipt: @unchecked Sendable {
    enum Outcome: Sendable, Equatable {
        case written
        case discarded
        case failed(String)
    }

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    func complete(_ outcome: Outcome) {
        let waiters: [CheckedContinuation<Outcome, Never>] = lock.withLock {
            guard self.outcome == nil else { return [] }
            self.outcome = outcome
            defer { self.waiters.removeAll() }
            return self.waiters
        }
        waiters.forEach { $0.resume(returning: outcome) }
    }

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            let resolved: Outcome? = lock.withLock {
                if let outcome { return outcome }
                waiters.append(continuation)
                return nil
            }
            if let resolved { continuation.resume(returning: resolved) }
        }
    }
}

/// Writes one connection's frames in order, one at a time. Disconnecting
/// discards queued frames; destroying finishes them. Queued awareness frames
/// are coalesced. Exceeding `capacity` queued frames while open fails the
/// connection, so that reconnect sync recovers the document instead of
/// buffering without limit. Frames added by `finish(appending:)` bypass the
/// capacity, because teardown cannot reconnect.
final class OutboundSender: @unchecked Sendable {
    enum Failure: Sendable {
        case overflow
        case write
    }

    private enum State {
        case open
        case finishing
        case closed
    }

    private let lock = NSLock()
    private let socket: any HocuspocusWebSocket
    private let capacity: Int
    private let onSocketSend: (@Sendable (Data) async -> Void)?
    private let onQueued: (@Sendable (Data) -> Void)?
    private let onDiscard: (@Sendable (Data) -> Void)?
    private let onFailure: @Sendable (Failure) -> Void
    private var queue: [OutboundFrame] = []
    private var state = State.open
    private var writing = false
    private var inFlight: OutboundFrame?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        socket: any HocuspocusWebSocket,
        capacity: Int,
        onSocketSend: (@Sendable (Data) async -> Void)?,
        onQueued: (@Sendable (Data) -> Void)? = nil,
        onDiscard: (@Sendable (Data) -> Void)?,
        onFailure: @escaping @Sendable (Failure) -> Void
    ) {
        self.socket = socket
        self.capacity = capacity
        self.onSocketSend = onSocketSend
        self.onQueued = onQueued
        self.onDiscard = onDiscard
        self.onFailure = onFailure
    }

    func enqueue(_ frame: OutboundFrame) {
        var dropped: [OutboundFrame] = []
        var overflowed = false
        let startWriter: Bool = lock.withLock {
            guard state == .open else {
                dropped = [frame]
                return false
            }
            coalesceQueuedAwareness(for: frame)
            guard queue.count < capacity else {
                dropped = queue + [frame]
                queue.removeAll()
                state = .closed
                overflowed = true
                resumeIdleWaitersIfIdle()
                return false
            }
            queue.append(frame)
            return claimWriter()
        }
        if dropped.isEmpty { onQueued?(frame.data) }
        drop(dropped)
        if overflowed {
            logger.error("outbound queue exceeded \(self.capacity) frames; reconnecting")
            onFailure(.overflow)
        }
        if startWriter {
            Task { await self.drain() }
        }
    }

    /// Drops queued frames and resolves every receipt, including the one for
    /// a write already handed to the socket, which may still complete. Nothing
    /// else is written, and `finish` callers stop waiting.
    func discard() {
        let (dropped, inFlight, waiters): ([OutboundFrame], OutboundFrame?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            state = .closed
            defer {
                queue.removeAll()
                idleWaiters.removeAll()
            }
            return (queue, self.inFlight, idleWaiters)
        }
        drop(dropped)
        inFlight?.receipt?.complete(.discarded)
        waiters.forEach { $0.resume() }
    }

    /// Stops accepting frames, appends `frames` without the capacity limit and
    /// waits until everything queued is written or the sender is closed.
    func finish(appending frames: [OutboundFrame]) async {
        var rejected: [OutboundFrame] = []
        let startWriter: Bool = lock.withLock {
            guard state == .open else {
                rejected = frames
                return false
            }
            state = .finishing
            for frame in frames {
                coalesceQueuedAwareness(for: frame)
                queue.append(frame)
            }
            return claimWriter()
        }
        if rejected.isEmpty { frames.forEach { onQueued?($0.data) } }
        drop(rejected)
        if startWriter {
            Task { await self.drain() }
        }
        await withCheckedContinuation { continuation in
            let idle = lock.withLock {
                guard writing else { return true }
                idleWaiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    private func drain() async {
        while let frame = nextFrame() {
            await onSocketSend?(frame.data)
            guard isWritable() else {
                drop([frame])
                continue
            }
            do {
                try await socket.send(frame.data)
                frame.receipt?.complete(.written)
            } catch {
                logger.error("failed to send message: \(error, privacy: .public)")
                frame.receipt?.complete(.failed(String(describing: error)))
                fail()
            }
        }
    }

    private func nextFrame() -> OutboundFrame? {
        lock.withLock {
            inFlight = nil
            guard state != .closed, !queue.isEmpty else {
                writing = false
                resumeIdleWaitersIfIdle()
                return nil
            }
            let frame = queue.removeFirst()
            inFlight = frame
            return frame
        }
    }

    private func isWritable() -> Bool {
        lock.withLock { state != .closed }
    }

    private func fail() {
        let dropped: [OutboundFrame] = lock.withLock {
            let wasClosed = state == .closed
            state = .closed
            defer { queue.removeAll() }
            return wasClosed ? [] : queue
        }
        drop(dropped)
        onFailure(.write)
    }

    private func drop(_ frames: [OutboundFrame]) {
        for frame in frames {
            onDiscard?(frame.data)
            frame.receipt?.complete(.discarded)
        }
    }

    // Call with `lock` held.
    private func coalesceQueuedAwareness(for frame: OutboundFrame) {
        guard case let .awareness(clients) = frame.kind else { return }
        let replaced = queue.filter { queued in
            guard case let .awareness(queuedClients) = queued.kind else { return false }
            return queuedClients.isSubset(of: clients)
        }
        guard !replaced.isEmpty else { return }
        queue.removeAll { queued in
            guard case let .awareness(queuedClients) = queued.kind else { return false }
            return queuedClients.isSubset(of: clients)
        }
        // Replaced frames are superseded rather than written.
        replaced.forEach { $0.receipt?.complete(.discarded) }
    }

    // Call with `lock` held. Returns true when the caller must start the writer.
    private func claimWriter() -> Bool {
        guard !writing, !queue.isEmpty else { return false }
        writing = true
        return true
    }

    // Call with `lock` held. The writer clears `writing` once the queue is
    // empty or the sender is closed.
    private func resumeIdleWaitersIfIdle() {
        guard !writing else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// Frames encoded by observer callbacks, which run outside the actor and may
/// still be running after native unsubscribe returns. Callbacks register
/// before encoding, so after `close()` the provider can await the ones already
/// accepted, then take every frame they appended.
final class ObservedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [OutboundFrame] = []
    private var active = 0
    private var closed = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Returns false once closed; otherwise pair with `end()`.
    func begin() -> Bool {
        lock.withLock {
            guard !closed else { return false }
            active += 1
            return true
        }
    }

    func append(_ frame: OutboundFrame) {
        lock.withLock { frames.append(frame) }
    }

    func end() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            active -= 1
            guard active == 0 else { return [] }
            defer { idleWaiters.removeAll() }
            return idleWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func takeAll() -> [OutboundFrame] {
        lock.withLock {
            defer { frames.removeAll() }
            return frames
        }
    }

    func close() {
        lock.withLock { closed = true }
    }

    /// Awaits callbacks that began before `close()`.
    func waitForAcceptedCallbacks(onWait: (@Sendable () -> Void)?) async {
        await withCheckedContinuation { continuation in
            let idle = lock.withLock {
                guard active > 0 else { return true }
                idleWaiters.append(continuation)
                return false
            }
            if idle {
                continuation.resume()
            } else {
                onWait?()
            }
        }
    }
}
