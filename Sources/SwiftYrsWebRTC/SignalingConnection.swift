import Foundation

/// One WebSocket to one signaling server. Maintains the connection (open →
/// receive loop → 30s keepalive ping → reconnect with exponential backoff) and
/// surfaces decoded frames. Subscribe/announce on open is the provider's job,
/// driven through `onOpen`.
actor SignalingConnection {
    private let url: URL
    private let initialDelay: Duration
    private let maxDelay: Duration
    private let maxRetries: Int
    private let onOpen: @Sendable (SignalingConnection) async -> Void
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
        onOpen: @escaping @Sendable (SignalingConnection) async -> Void,
        onMessage: @escaping @Sendable (IncomingSignalingMessage) async -> Void
    ) {
        self.url = url
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.maxRetries = maxRetries
        self.onOpen = onOpen
        self.onMessage = onMessage
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await runLoop() }
    }

    func send(_ data: Data) async {
        try? await task?.send(.data(data))
    }

    func stop() {
        stopped = true
        pinger?.cancel()
        pinger = nil
        loop?.cancel()
        loop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    static func reconnectDelay(attempt: Int, initialDelay: Duration, maxDelay: Duration) -> Duration {
        var delay = initialDelay
        guard attempt > 0 else {
            return min(delay, maxDelay)
        }
        for _ in 0..<attempt {
            delay = min(delay + delay, maxDelay)
        }
        return delay
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
                let delay = Self.reconnectDelay(attempt: attempt, initialDelay: initialDelay, maxDelay: maxDelay)
                attempt += 1
                try? await Task.sleep(for: delay)
                continue
            }
            await onOpen(self)
            startPing()
            let sawFrame = await receiveUntilFailure(on: task)
            session.invalidateAndCancel()
            webRTCDebug("signaling \(url.absoluteString) receive loop ended; reconnecting")
            stopPing()
            if stopped { break }
            if sawFrame {
                attempt = 0
            }
            guard attempt < maxRetries else { break }
            let delay = Self.reconnectDelay(attempt: attempt, initialDelay: initialDelay, maxDelay: maxDelay)
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
                if let message = try? SignalingCodec.decode(data) {
                    await onMessage(message)
                }
            } catch {
                return sawFrame
            }
        }
        return sawFrame
    }

    private static func waitForOpen(_ observer: WebSocketOpenObserver, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let opened = observer.opened {
                return opened
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
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

private final class WebSocketOpenObserver: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: Bool?

    var opened: Bool? {
        lock.withLock { _opened }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.withLock {
            _opened = true
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        lock.withLock {
            if _opened == nil {
                _opened = false
            }
        }
    }
}
