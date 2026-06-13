import Foundation
import SwiftYrs

/// One WebSocket to one signaling server. Maintains the connection (open →
/// receive loop → 30s keepalive ping → reconnect with exponential backoff) and
/// surfaces decoded frames. Subscribe/announce on open is the provider's job,
/// driven through `onOpen`.
actor SignalingConnection {
    private let url: URL
    private let initialDelay: Duration
    private let maxDelay: Duration
    private let maxRetries: Int
    private let cipher: SignalingCipher?
    private let onOpen: @Sendable (SignalingConnection) async -> Void
    private let onClose: @Sendable (SignalingConnection) async -> Void
    private let onMessage: @Sendable (IncomingSignalingMessage) async -> Void

    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var stopped = false

    init(
        url: URL,
        initialDelay: Duration,
        maxDelay: Duration,
        maxRetries: Int,
        cipher: SignalingCipher?,
        onOpen: @escaping @Sendable (SignalingConnection) async -> Void,
        onClose: @escaping @Sendable (SignalingConnection) async -> Void,
        onMessage: @escaping @Sendable (IncomingSignalingMessage) async -> Void
    ) {
        self.url = url
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.maxRetries = maxRetries
        self.cipher = cipher
        self.onOpen = onOpen
        self.onClose = onClose
        self.onMessage = onMessage
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await runLoop() }
    }

    func send(_ data: Data) async {
        guard !stopped else { return }
        try? await task?.send(.data(data))
    }

    /// Cancels the receive loop and keepalive, then awaits the loop's actual
    /// termination so the caller can rely on the connection being fully torn
    /// down on return — no reconnect can fire after this resumes. Idempotent and
    /// safe to call concurrently: multiple callers await the same loop task.
    func stop() async {
        stopped = true
        pinger?.cancel()
        pinger = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        loop?.cancel()
        await loop?.value
        loop = nil
    }

    private func runLoop() async {
        var attempt = 0
        while !stopped {
            let openObserver = WebSocketOpenObserver()
            let session = URLSession(configuration: .default, delegate: openObserver, delegateQueue: nil)
            let task = session.webSocketTask(with: url)
            self.task = task
            task.resume()
            guard await Self.waitForOpen(openObserver) else {
                session.invalidateAndCancel()
                if stopped { break }
                guard attempt < maxRetries else { break }
                let delay = Backoff.reconnectDelay(attempt: attempt, initialDelay: initialDelay, maxDelay: maxDelay)
                attempt += 1
                try? await Task.sleep(for: delay)
                continue
            }
            guard !stopped else {
                session.invalidateAndCancel()
                break
            }
            await onOpen(self)
            guard !stopped else {
                session.invalidateAndCancel()
                break
            }
            startPing()
            let sawFrame = await receiveUntilFailure(on: task)
            session.invalidateAndCancel()
            stopPing()
            await onClose(self)
            if stopped {
                webRTCDebug("signaling \(url.absoluteString) receive loop ended; stopping")
                break
            }
            webRTCDebug("signaling \(url.absoluteString) receive loop ended; reconnecting")
            if sawFrame {
                attempt = 0
            }
            guard attempt < maxRetries else { break }
            let delay = Backoff.reconnectDelay(attempt: attempt, initialDelay: initialDelay, maxDelay: maxDelay)
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }

    private func receiveUntilFailure(on task: URLSessionWebSocketTask) async -> Bool {
        var sawFrame = false
        while !stopped {
            do {
                let frame = try await task.receive()
                sawFrame = true
                guard let data = Self.data(from: frame) else { continue }
                if let message = try? SignalingCodec.decode(data, cipher: cipher) {
                    await onMessage(message)
                }
            } catch {
                return sawFrame
            }
        }
        return sawFrame
    }

    private static func waitForOpen(_ observer: WebSocketOpenObserver, timeout: Duration = .seconds(5)) async -> Bool {
        // Race the delegate's open/close callback against a timeout. The open
        // observer resolves to `false` on cancellation (stop/destroy) too, so
        // teardown does not block for the full timeout on a dead server.
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await observer.awaitOpened() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    private func startPing() {
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                await self.send(SignalingCodec.ping())
            }
        }
    }

    private func stopPing() {
        pinger?.cancel()
        pinger = nil
    }

    private static func data(from frame: URLSessionWebSocketTask.Message) -> Data? {
        switch frame {
        case let .data(data):
            return data
        case let .string(string):
            return string.data(using: .utf8)
        @unknown default:
            return nil
        }
    }
}

/// Bridges `URLSession`'s open/close delegate callbacks into a single awaitable
/// result. `awaitOpened()` suspends until the socket opens (`true`), closes
/// before opening (`false`), or the awaiting task is cancelled (`false`). The
/// result latches, so callers that await after the callback fired still see it.
private final class WebSocketOpenObserver: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func awaitOpened() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if let result {
                        continuation.resume(returning: result)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            resolve(false)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        resolve(true)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        resolve(false)
    }

    /// Latches the first outcome and resumes a waiter exactly once.
    private func resolve(_ value: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}
