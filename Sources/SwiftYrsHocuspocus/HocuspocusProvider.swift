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

public actor HocuspocusProvider {
    public static let productName = "SwiftYrsHocuspocus"

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
    private let connectionStatusContinuation: AsyncStream<ConnectionStatus>.Continuation
    private let isSyncedContinuation: AsyncStream<Bool>.Continuation
    private let authStatusContinuation: AsyncStream<AuthStatus>.Continuation
    private let statelessContinuation: AsyncStream<String>.Continuation
    private var webSocket: (any HocuspocusWebSocket)?
    private var receiveTask: Task<Void, Never>?
    private var documentObservation: Observation?
    private var awarenessObservation: Observation?
    private let documentObservationGate = RemoteApplyGate()
    private let awarenessObservationGate = RemoteApplyGate()
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

        let syncStep1 = try YSyncMessage.syncStep1(document.stateVector())
        try await webSocket.send(HocuspocusMessage.sync(documentName: name, syncStep1).encoded())
        if let awareness, try awareness.localState() != nil {
            try await webSocket.send(HocuspocusMessage.awareness(
                documentName: name,
                awareness.encodeUpdate(for: [awareness.clientID])
            ).encoded())
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
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
                guard let update = event.updateV1 else {
                    return
                }
                Task { [weak self] in
                    await self?.sendLocalUpdate(update)
                }
            }
        }
        if awarenessObservation == nil, let awareness {
            awarenessObservation = try awareness.observeUpdate { [weak self, awarenessObservationGate, awareness] event in
                guard !awarenessObservationGate.isApplyingRemote else {
                    return
                }
                let clientIDs = event.changedAwarenessClientIDs
                guard !clientIDs.isEmpty, let update = try? awareness.encodeUpdate(for: clientIDs) else {
                    return
                }
                Task { [weak self] in
                    await self?.sendAwareness(update)
                }
            }
        }
    }

    private func handle(_ data: Data) async throws {
        let message = try HocuspocusMessage.decode(data)
        switch message {
        case let .sync(_, syncMessage):
            try await handle(syncMessage)
        case let .syncMessages(_, syncMessages):
            for syncMessage in syncMessages {
                try await handle(syncMessage)
            }
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

    private func handle(_ syncMessage: YSyncMessage) async throws {
        switch syncMessage {
        case let .syncStep1(stateVector, _):
            guard let webSocket else {
                return
            }
            let update = try document.encodeStateAsUpdateV1(from: stateVector)
            try await webSocket.send(HocuspocusMessage.sync(
                documentName: name,
                YSyncMessage.syncStep2(update)
            ).encoded())
        case let .syncStep2(update, _):
            try applyRemote(update)
            isSyncedContinuation.yield(true)
        case let .update(update, _):
            try applyRemote(update)
        default:
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
        guard let webSocket, let awareness else {
            return
        }
        let clientIDs = try awareness.states().map(\.clientID)
        guard !clientIDs.isEmpty else {
            return
        }
        try await webSocket.send(HocuspocusMessage.awareness(
            documentName: name,
            awareness.encodeUpdate(for: clientIDs)
        ).encoded())
    }

    private func applyRemote(_ update: YUpdate) throws {
        // The update observer fires synchronously during commit; gate it so our
        // own applied remote update is not echoed back to the server. This is
        // robust regardless of how yrs re-encodes the update bytes.
        try documentObservationGate.withApplyingRemote {
            try document.write(origin: "SwiftYrsHocuspocus") { transaction in
                try transaction.apply(update)
            }
        }
    }

    private func applyAwareness(_ update: YAwarenessUpdate) throws {
        guard let awareness else {
            return
        }
        try awarenessObservationGate.withApplyingRemote {
            try awareness.applyUpdate(update)
        }
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
