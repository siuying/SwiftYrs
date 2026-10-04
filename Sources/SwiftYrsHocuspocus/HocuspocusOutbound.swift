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
}

/// Writes one connection's frames in order, one at a time. Disconnecting
/// discards queued frames; destroying finishes them. Queued awareness frames
/// are coalesced, and exceeding `capacity` queued frames fails the connection
/// so that reconnect sync recovers the document instead of buffering without
/// limit.
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
    private let onDiscard: (@Sendable (Data) -> Void)?
    private let onFailure: @Sendable (Failure) -> Void
    private var queue: [OutboundFrame] = []
    private var state = State.open
    private var writing = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        socket: any HocuspocusWebSocket,
        capacity: Int,
        onSocketSend: (@Sendable (Data) async -> Void)?,
        onDiscard: (@Sendable (Data) -> Void)?,
        onFailure: @escaping @Sendable (Failure) -> Void
    ) {
        self.socket = socket
        self.capacity = capacity
        self.onSocketSend = onSocketSend
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
            if case let .awareness(clients) = frame.kind {
                queue.removeAll { queued in
                    guard case let .awareness(queuedClients) = queued.kind else { return false }
                    return queuedClients.isSubset(of: clients)
                }
            }
            guard queue.count < capacity else {
                dropped = queue + [frame]
                queue.removeAll()
                state = .closed
                overflowed = true
                resumeIdleWaitersIfIdle()
                return false
            }
            queue.append(frame)
            guard !writing else { return false }
            writing = true
            return true
        }
        dropped.forEach { onDiscard?($0.data) }
        if overflowed {
            logger.error("outbound queue exceeded \(self.capacity) frames; reconnecting")
            onFailure(.overflow)
        }
        if startWriter {
            Task { await self.drain() }
        }
    }

    /// Drops queued frames. A write already handed to the socket may complete,
    /// but nothing else is written.
    func discard() {
        let dropped: [OutboundFrame] = lock.withLock {
            state = .closed
            defer { queue.removeAll() }
            resumeIdleWaitersIfIdle()
            return queue
        }
        dropped.forEach { onDiscard?($0.data) }
    }

    /// Stops accepting frames and waits until queued frames are written or the
    /// sender is closed.
    func finish() async {
        await withCheckedContinuation { continuation in
            let idle = lock.withLock {
                if state == .open { state = .finishing }
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
                onDiscard?(frame.data)
                continue
            }
            do {
                try await socket.send(frame.data)
            } catch {
                logger.error("failed to send message: \(error, privacy: .public)")
                fail()
            }
        }
    }

    private func nextFrame() -> OutboundFrame? {
        lock.withLock {
            guard state != .closed, !queue.isEmpty else {
                writing = false
                resumeIdleWaitersIfIdle()
                return nil
            }
            return queue.removeFirst()
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
        dropped.forEach { onDiscard?($0.data) }
        onFailure(.write)
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
