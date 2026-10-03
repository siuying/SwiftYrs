import Foundation
import OSLog
import SwiftYrs

private let logger = Logger(subsystem: "SwiftYrsHocuspocus", category: "provider")

public enum ConnectionStatus: Equatable, Sendable {
    case connecting
    case connected
    case disconnected
}

public enum AuthStatus: Equatable, Sendable {
    case authenticated(scope: String)
    case denied(reason: String)
}

protocol HocuspocusWebSocket: Sendable {
    func resume()
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

/// A non-null local awareness state, including `[:]`, keeps idle connections alive.
/// With null or disabled awareness, an idle server may close the connection with 4408.
public actor HocuspocusProvider {
    public static let productName = "SwiftYrsHocuspocus"
    // Match CloudKitProvider's transaction retry policy.
    private static let maxTransactionAttempts = 8
    private static let transactionRetryDelay: Duration = .milliseconds(5)

    struct TestHooks: Sendable {
        static let none = TestHooks()

        let onTransactionConflict: (@Sendable () -> Void)?
        let onSyncMessageHandled: (@Sendable (Int) -> Void)?
        let onSyncStatusEmitted: (@Sendable () -> Void)?
        let transactionRetryWait: (@Sendable () async throws -> Void)?

        init(
            onTransactionConflict: (@Sendable () -> Void)? = nil,
            onSyncMessageHandled: (@Sendable (Int) -> Void)? = nil,
            onSyncStatusEmitted: (@Sendable () -> Void)? = nil,
            transactionRetryWait: (@Sendable () async throws -> Void)? = nil
        ) {
            self.onTransactionConflict = onTransactionConflict
            self.onSyncMessageHandled = onSyncMessageHandled
            self.onSyncStatusEmitted = onSyncStatusEmitted
            self.transactionRetryWait = transactionRetryWait
        }
    }

    public nonisolated let connectionStatus: AsyncStream<ConnectionStatus>
    public nonisolated let isSynced: AsyncStream<Bool>
    public nonisolated let authStatus: AsyncStream<AuthStatus>
    public nonisolated let stateless: AsyncStream<String>

    private let url: URL
    private let name: String
    private let document: YDoc
    private let awareness: YAwareness?
    private let token: (@Sendable () async throws -> String)?
    private let maxRetries: Int
    private let initialDelay: Duration
    private let maxDelay: Duration
    private let webSocketFactory: @Sendable (URL) -> any HocuspocusWebSocket
    private let testHooks: TestHooks
    private let connectionStatusContinuation: AsyncStream<ConnectionStatus>.Continuation
    private let isSyncedContinuation: AsyncStream<Bool>.Continuation
    private let authStatusContinuation: AsyncStream<AuthStatus>.Continuation
    private let statelessContinuation: AsyncStream<String>.Continuation
    private var webSocket: (any HocuspocusWebSocket)?
    private var receiveTask: Task<Void, Never>?
    private var documentObservation: Observation?
    private var awarenessObservation: Observation?
    private var awarenessTask: Task<Void, Never>?
    private var awarenessTaskID: UUID?
    private let documentObservationGate = RemoteApplyGate()
    private let awarenessOrigin = UUID().uuidString
    private var retryAttempt = 0
    private var disconnectRequested = false

    public init(
        url: URL,
        name: String,
        document: YDoc,
        awareness: YAwareness? = nil,
        token: (@Sendable () async throws -> String)? = nil,
        maxRetries: Int = .max,
        initialDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(30)
    ) {
        self.init(
            url: url,
            name: name,
            document: document,
            awareness: awareness,
            token: token,
            maxRetries: maxRetries,
            initialDelay: initialDelay,
            maxDelay: maxDelay,
            webSocketFactory: { url in
                URLSessionHocuspocusWebSocket(url: url)
            }
        )
    }

    init(
        url: URL,
        name: String,
        document: YDoc,
        awareness: YAwareness? = nil,
        token: (@Sendable () async throws -> String)? = nil,
        maxRetries: Int = .max,
        initialDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(30),
        testHooks: TestHooks = .none,
        webSocketFactory: @escaping @Sendable (URL) -> any HocuspocusWebSocket
    ) {
        self.url = url
        self.name = name
        self.document = document
        self.awareness = awareness
        self.token = token
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.testHooks = testHooks
        self.webSocketFactory = webSocketFactory

        let connectionStatusPair = AsyncStream.makeStream(of: ConnectionStatus.self)
        self.connectionStatus = connectionStatusPair.stream
        self.connectionStatusContinuation = connectionStatusPair.continuation

        let isSyncedPair = AsyncStream.makeStream(of: Bool.self)
        self.isSynced = isSyncedPair.stream
        self.isSyncedContinuation = isSyncedPair.continuation

        let authStatusPair = AsyncStream.makeStream(of: AuthStatus.self)
        self.authStatus = authStatusPair.stream
        self.authStatusContinuation = authStatusPair.continuation

        let statelessPair = AsyncStream.makeStream(of: String.self)
        self.stateless = statelessPair.stream
        self.statelessContinuation = statelessPair.continuation
    }

    public func connect() async throws {
        disconnectRequested = false
        retryAttempt = 0
        try await openWebSocket()
    }

    public func disconnect() {
        disconnectRequested = true
        stopAwarenessMaintenance()
        receiveTask?.cancel()
        receiveTask = nil
        documentObservation?.cancel()
        documentObservation = nil
        awarenessObservation?.cancel()
        awarenessObservation = nil
        clearRemoteAwarenessStates()
        webSocket?.close()
        webSocket = nil
        connectionStatusContinuation.yield(.disconnected)
    }

    deinit {
        awarenessTask?.cancel()
    }

    public func sendStateless(_ payload: String) async {
        guard let webSocket else {
            return
        }
        do {
            try await webSocket.send(HocuspocusMessage.stateless(documentName: name, payload: payload).encoded())
        } catch {
            logger.error("failed to send stateless message: \(error, privacy: .public)")
        }
    }

    private func openWebSocket() async throws {
        connectionStatusContinuation.yield(.connecting)
        let webSocket = webSocketFactory(url)
        self.webSocket = webSocket
        webSocket.resume()
        connectionStatusContinuation.yield(.connected)
        try startObservingIfNeeded()
        try await sendAuthToken(on: webSocket)

        var initialMessages: [YSyncMessage] = []
        let initialSyncEngine = makeSyncEngine { message in
            initialMessages.append(message)
        }
        try initialSyncEngine.initialSync(
            includeAwarenessQuery: false,
            includeKnownAwarenessStates: false
        )
        try await sendEngineMessages(initialMessages, on: webSocket)
        if let awareness, try awareness.localState() != nil {
            try await webSocket.send(HocuspocusMessage.awareness(
                documentName: name,
                awareness.encodeUpdate(for: [awareness.clientID])
            ).encoded())
        }

        guard !disconnectRequested else { return }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        startAwarenessMaintenance()
    }

    private func receiveLoop() async {
        guard let webSocket else {
            return
        }
        do {
            while !Task.isCancelled {
                let data = try await webSocket.receive()
                // A received frame proves the connection is healthy, so reset the
                // backoff counter; otherwise transient drops accumulate across
                // independent outages and eventually exhaust maxRetries.
                retryAttempt = 0
                try await handle(data)
            }
        } catch is CancellationError {
        } catch {
            await reconnectAfterUnexpectedDisconnect()
        }
    }

    private func reconnectAfterUnexpectedDisconnect() async {
        stopAwarenessMaintenance()
        guard !disconnectRequested else {
            return
        }
        webSocket?.close()
        webSocket = nil
        connectionStatusContinuation.yield(.disconnected)
        guard retryAttempt < maxRetries else {
            return
        }
        let delay = Backoff.reconnectDelay(
            attempt: retryAttempt,
            initialDelay: initialDelay,
            maxDelay: maxDelay
        )
        retryAttempt += 1
        do {
            try await Task.sleep(for: delay)
            guard !disconnectRequested else {
                return
            }
            try await openWebSocket()
        } catch is CancellationError {
        } catch {
            await reconnectAfterUnexpectedDisconnect()
        }
    }

    private func startObservingIfNeeded() throws {
        if documentObservation == nil {
            documentObservation = try document.observeUpdates { [weak self, documentObservationGate] event in
                guard !documentObservationGate.isApplyingRemote else {
                    return
                }
                guard case let .update(update) = event else {
                    return
                }
                Task { [weak self] in
                    await self?.sendLocalUpdate(update)
                }
            }
        }
        if awarenessObservation == nil, let awareness {
            awarenessObservation = try awareness.observeUpdate { [weak self, awareness, awarenessOrigin] event in
                guard case let .awarenessUpdate(change) = event else {
                    return
                }
                guard change.origin != awarenessOrigin else { return }
                let clientIDs = change.changed
                guard !clientIDs.isEmpty, let update = try? awareness.encodeUpdate(for: clientIDs) else {
                    return
                }
                Task { [weak self] in
                    await self?.sendAwareness(update)
                }
            }
        }
    }

    private func startAwarenessMaintenance() {
        stopAwarenessMaintenance()
        guard let awareness else { return }
        let id = UUID()
        awarenessTaskID = id
        let interval = awareness.timing.checkInterval
        awarenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch { return }
                guard await self?.checkAwarenessTimeouts(id: id) == true else { return }
            }
        }
    }

    private func stopAwarenessMaintenance() {
        awarenessTaskID = nil
        awarenessTask?.cancel()
        awarenessTask = nil
    }

    private func checkAwarenessTimeouts(id: UUID) -> Bool {
        guard awarenessTaskID == id, webSocket != nil, !Task.isCancelled else { return false }
        do {
            try awareness?.checkTimeouts()
        } catch {
            logger.error("failed to check awareness timeouts: \(error, privacy: .public)")
        }
        return true
    }

    private func handle(_ data: Data) async throws {
        let message = try HocuspocusMessage.decode(data)
        switch message {
        case let .sync(_, syncMessage):
            try await handle([syncMessage])
        case let .syncMessages(_, syncMessages):
            try await handle(syncMessages)
        case let .auth(_, auth):
            try await handle(auth)
        case let .awareness(_, update):
            try applyAwareness(update)
        case .queryAwareness:
            try await sendKnownAwarenessStates()
        case let .stateless(_, payload):
            statelessContinuation.yield(payload)
        default:
            return
        }
    }

    private func handle(_ syncMessages: [YSyncMessage]) async throws {
        guard let webSocket else {
            return
        }
        var attempts = 0
        while true {
            try Task.checkCancellation()

            var outgoing: [YSyncMessage] = []
            let syncEngine = makeSyncEngine { message in
                outgoing.append(message)
            }
            var didSync = false
            do {
                for (index, message) in syncMessages.enumerated() {
                    let result = try syncEngine.handle(message)
                    didSync = didSync || result.didSync
                    testHooks.onSyncMessageHandled?(index)
                }
            } catch YError.transactionConflict {
                testHooks.onTransactionConflict?()
                attempts += 1
                guard attempts < Self.maxTransactionAttempts else {
                    // Reconnect after exhaustion so a full resync can recover this frame.
                    logger.notice("incoming sync transaction conflict persisted after \(Self.maxTransactionAttempts) attempts; reconnecting")
                    throw YError.transactionConflict
                }
                if let transactionRetryWait = testHooks.transactionRetryWait {
                    try await transactionRetryWait()
                } else {
                    try await Task.sleep(for: Self.transactionRetryDelay)
                }
                continue
            }

            try Task.checkCancellation()
            try await sendEngineMessages(outgoing, on: webSocket)
            if didSync {
                testHooks.onSyncStatusEmitted?()
                isSyncedContinuation.yield(true)
            }
            return
        }
    }

    private func handle(_ auth: HocuspocusAuthMessage) async throws {
        switch auth {
        case .token:
            guard let webSocket else {
                return
            }
            try await sendAuthToken(on: webSocket)
        case let .permissionDenied(reason):
            authStatusContinuation.yield(.denied(reason: reason))
        case let .authenticated(scope):
            authStatusContinuation.yield(.authenticated(scope: scope))
        }
    }

    private func sendAuthToken(on webSocket: any HocuspocusWebSocket) async throws {
        let value = try await token?() ?? ""
        try await webSocket.send(HocuspocusMessage.auth(
            documentName: name,
            .token(value, version: Self.productName)
        ).encoded())
    }

    private func sendLocalUpdate(_ update: YUpdate) async {
        guard let webSocket else {
            return
        }
        do {
            let syncMessage = try YSyncMessage.update(update)
            try await webSocket.send(HocuspocusMessage.sync(documentName: name, syncMessage).encoded())
        } catch {
            logger.error("failed to send local update: \(error, privacy: .public)")
        }
    }

    private func sendAwareness(_ update: YAwarenessUpdate) async {
        guard let webSocket else {
            return
        }
        do {
            try await webSocket.send(HocuspocusMessage.awareness(documentName: name, update).encoded())
        } catch {
            logger.error("failed to send awareness update: \(error, privacy: .public)")
        }
    }

    private func sendKnownAwarenessStates() async throws {
        guard let webSocket, awareness != nil else {
            return
        }
        var outgoing: [YSyncMessage] = []
        let syncEngine = makeSyncEngine { message in
            outgoing.append(message)
        }
        try syncEngine.sendKnownAwarenessStates()
        try await sendEngineMessages(outgoing, on: webSocket)
    }

    private func makeSyncEngine(send: @escaping (YSyncMessage) throws -> Void) -> YSyncEngine {
        YSyncEngine(
            doc: document,
            awareness: awareness,
            send: send,
            applyUpdate: { [document, documentObservationGate] update in
                try documentObservationGate.withApplyingRemote {
                    try document.write(origin: "SwiftYrsHocuspocus") { transaction in
                        try transaction.apply(update)
                    }
                }
            },
            applyAwarenessUpdate: { [awareness, awarenessOrigin] update in
                guard let awareness else {
                    return
                }
                try awareness.applyUpdate(update, origin: awarenessOrigin)
            }
        )
    }

    private func sendEngineMessages(
        _ messages: [YSyncMessage],
        on webSocket: any HocuspocusWebSocket
    ) async throws {
        for message in messages {
            switch message {
            case let .awareness(update, _):
                try await webSocket.send(HocuspocusMessage.awareness(documentName: name, update).encoded())
            default:
                try await webSocket.send(HocuspocusMessage.sync(documentName: name, message).encoded())
            }
        }
    }

    private func applyAwareness(_ update: YAwarenessUpdate) throws {
        guard let awareness else {
            return
        }
        try awareness.applyUpdate(update, origin: awarenessOrigin)
    }

    private func clearRemoteAwarenessStates() {
        guard let awareness, let states = try? awareness.states() else {
            return
        }
        for state in states where state.clientID != awareness.clientID {
            awareness.removeState(for: state.clientID)
        }
    }
}

/// Guards against echoing our own applied remote update back to the server.
/// `applyRemote` raises the flag around `document.write`; the document update
/// observer fires synchronously inside that write, on the same thread, reads
/// the flag, and skips re-sending. The flag is only set/read/cleared on that
/// one thread within a single apply, but it still needs synchronization for
/// `Sendable` correctness because the observer is a nonisolated C callback. The
/// lock is taken only to touch the flag — never held across `body()` — so the
/// observer's read during `body()` cannot deadlock against it.
private final class RemoteApplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var applyingRemote = false

    var isApplyingRemote: Bool {
        lock.withLock { applyingRemote }
    }

    func withApplyingRemote<T>(_ body: () throws -> T) rethrows -> T {
        lock.withLock { applyingRemote = true }
        defer {
            lock.withLock { applyingRemote = false }
        }
        return try body()
    }
}

private final class URLSessionHocuspocusWebSocket: HocuspocusWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        self.task = URLSession.shared.webSocketTask(with: url)
    }

    func resume() {
        task.resume()
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        let message = try await task.receive()
        switch message {
        case let .data(data):
            return data
        case let .string(string):
            guard let data = string.data(using: .utf8) else {
                throw HocuspocusCodecError.malformedMessage
            }
            return data
        @unknown default:
            throw HocuspocusCodecError.malformedMessage
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
