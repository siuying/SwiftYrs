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

public enum HocuspocusProviderError: Error, Equatable, Sendable {
    /// The server sent a message larger than the provider's
    /// `maximumMessageSize`. The provider disconnects instead of reconnecting,
    /// because the same sync would fail again; raise the limit and call
    /// `connect()` to retry.
    case messageTooLarge(limit: Int)
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
    /// URLSessionWebSocketTask's own default is 1 MiB, which a document's first
    /// sync message easily exceeds.
    public static let defaultMaximumMessageSize = 64 * 1024 * 1024
    static let defaultOutboundCapacity = 1024
    static let defaultTeardownDeadline: Duration = .seconds(5)
    // Match CloudKitProvider's transaction retry policy.
    private static let maxTransactionAttempts = 8
    private static let transactionRetryDelay: Duration = .milliseconds(5)

    struct TestHooks: Sendable {
        static let none = TestHooks()

        let onTransactionConflict: (@Sendable () async -> Void)?
        let onSyncMessageHandled: (@Sendable (Int) async -> Void)?
        let onAwarenessForwarded: (@Sendable () -> Void)?
        let onDocumentForwarded: (@Sendable () -> Void)?
        let awarenessCheckWait: (@Sendable () async throws -> Void)?
        let onAwarenessCheck: (@Sendable (Bool) -> Void)?
        let onSyncStatusEmitted: (@Sendable () -> Void)?
        let transactionRetryWait: (@Sendable () async throws -> Void)?
        let onSocketSend: (@Sendable (Data) async -> Void)?
        let onFrameQueued: (@Sendable (Data) -> Void)?
        let onFrameDiscarded: (@Sendable (Data) -> Void)?
        let onInboundFrame: (@Sendable (Bool) -> Void)?
        let onObserverDrainWait: (@Sendable () -> Void)?
        let onDestroyJoined: (@Sendable () -> Void)?
        let teardownDeadlineWait: (@Sendable () async -> Void)?

        init(
            onTransactionConflict: (@Sendable () async -> Void)? = nil,
            onSyncMessageHandled: (@Sendable (Int) async -> Void)? = nil,
            onAwarenessForwarded: (@Sendable () -> Void)? = nil,
            onDocumentForwarded: (@Sendable () -> Void)? = nil,
            awarenessCheckWait: (@Sendable () async throws -> Void)? = nil,
            onAwarenessCheck: (@Sendable (Bool) -> Void)? = nil,
            onSyncStatusEmitted: (@Sendable () -> Void)? = nil,
            transactionRetryWait: (@Sendable () async throws -> Void)? = nil,
            onSocketSend: (@Sendable (Data) async -> Void)? = nil,
            onFrameQueued: (@Sendable (Data) -> Void)? = nil,
            onFrameDiscarded: (@Sendable (Data) -> Void)? = nil,
            onInboundFrame: (@Sendable (Bool) -> Void)? = nil,
            onObserverDrainWait: (@Sendable () -> Void)? = nil,
            onDestroyJoined: (@Sendable () -> Void)? = nil,
            teardownDeadlineWait: (@Sendable () async -> Void)? = nil
        ) {
            self.onTransactionConflict = onTransactionConflict
            self.onSyncMessageHandled = onSyncMessageHandled
            self.onAwarenessForwarded = onAwarenessForwarded
            self.onDocumentForwarded = onDocumentForwarded
            self.awarenessCheckWait = awarenessCheckWait
            self.onAwarenessCheck = onAwarenessCheck
            self.onSyncStatusEmitted = onSyncStatusEmitted
            self.transactionRetryWait = transactionRetryWait
            self.onSocketSend = onSocketSend
            self.onFrameQueued = onFrameQueued
            self.onFrameDiscarded = onFrameDiscarded
            self.onInboundFrame = onInboundFrame
            self.onObserverDrainWait = onObserverDrainWait
            self.onDestroyJoined = onDestroyJoined
            self.teardownDeadlineWait = teardownDeadlineWait
        }
    }

    public nonisolated let connectionStatus: AsyncStream<ConnectionStatus>
    public nonisolated let isSynced: AsyncStream<Bool>
    public nonisolated let authStatus: AsyncStream<AuthStatus>
    public nonisolated let stateless: AsyncStream<String>
    /// Errors that stop the provider from reconnecting on its own.
    public nonisolated let errors: AsyncStream<HocuspocusProviderError>

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
    private let errorsContinuation: AsyncStream<HocuspocusProviderError>.Continuation
    private let outboundCapacity: Int
    private let teardownDeadline: Duration
    private var connection: Connection?
    private var connectionGeneration: UInt64 = 0
    private var observedFrames: ObservedFrames?
    private var destroyTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var documentObservation: Observation?
    private var awarenessObservation: Observation?
    private var awarenessTask: Task<Void, Never>?
    private var awarenessTaskID: UUID?
    private let documentObservationGate = RemoteApplyGate()
    private let awarenessOrigin = UUID().uuidString
    private var retryAttempt = 0
    private var disconnectRequested = false

    private struct Connection {
        let generation: UInt64
        let socket: any HocuspocusWebSocket
        let sender: OutboundSender
    }

    /// Superseded work after a suspension, such as a handshake continuing after
    /// disconnect or destroy.
    private struct StaleConnection: Error {}

    public init(
        url: URL,
        name: String,
        document: YDoc,
        awareness: YAwareness? = nil,
        token: (@Sendable () async throws -> String)? = nil,
        maxRetries: Int = .max,
        initialDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(30),
        maximumMessageSize: Int = HocuspocusProvider.defaultMaximumMessageSize
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
                URLSessionHocuspocusWebSocket(url: url, maximumMessageSize: maximumMessageSize)
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
        outboundCapacity: Int = HocuspocusProvider.defaultOutboundCapacity,
        teardownDeadline: Duration = HocuspocusProvider.defaultTeardownDeadline,
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
        self.outboundCapacity = outboundCapacity
        self.teardownDeadline = teardownDeadline
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

        let errorsPair = AsyncStream.makeStream(of: HocuspocusProviderError.self)
        self.errors = errorsPair.stream
        self.errorsContinuation = errorsPair.continuation
        Task { [weak self] in await self?.startAwarenessMaintenance() }
    }

    /// Does nothing after `destroy()`.
    public func connect() async throws {
        guard !isDestroyed else { return }
        disconnectRequested = false
        retryAttempt = 0
        do {
            try await openWebSocket()
        } catch is StaleConnection {
        }
    }

    /// Temporarily disconnects, keeping local awareness for a later `connect()`.
    /// Queued outbound messages are discarded and the socket closes immediately;
    /// use `destroy()` to tell peers that this client left.
    public func disconnect() {
        guard !isDestroyed else { return }
        disconnectRequested = true
        receiveTask?.cancel()
        receiveTask = nil
        stopObserving()?.close()
        clearRemoteAwarenessStates()
        dropConnection()
        connectionStatusContinuation.yield(.disconnected)
    }

    /// Terminal teardown, matching `destroy()` in @hocuspocus/provider 4.7.
    /// Clears local awareness with origin `"provider destroy"`, even when it is
    /// already null, then awaits outstanding writes, including that final
    /// awareness update, before closing the socket. Event streams finish
    /// afterwards. If the writes have not finished within 5 seconds, it logs,
    /// discards them and closes the socket anyway, so a stuck socket cannot hang
    /// the caller. Concurrent callers wait for the same teardown, and later
    /// calls, including `connect()`, do nothing.
    public func destroy() async {
        if let destroyTask {
            testHooks.onDestroyJoined?()
            await destroyTask.value
            return
        }
        let task = Task { await self.tearDown() }
        destroyTask = task
        await task.value
    }

    deinit {
        awarenessTask?.cancel()
    }

    /// Returns once the message is written to the socket, or dropped because
    /// the connection closed first. Does nothing while disconnected.
    public func sendStateless(_ payload: String) async {
        guard connection != nil else { return }
        let receipt = SendReceipt()
        enqueue(HocuspocusMessage.stateless(documentName: name, payload: payload).encoded(), receipt: receipt)
        switch await receipt.wait() {
        case .written:
            break
        case .discarded:
            logger.notice("stateless message dropped because the connection closed")
        case let .failed(error):
            logger.error("failed to send stateless message: \(error, privacy: .public)")
        }
    }

    private var isDestroyed: Bool { destroyTask != nil }

    private func isCurrent(_ generation: UInt64) -> Bool {
        !isDestroyed && connection?.generation == generation
    }

    private func ensureCurrent(_ generation: UInt64) throws {
        guard isCurrent(generation) else { throw StaleConnection() }
    }

    private func tearDown() async {
        disconnectRequested = true
        stopAwarenessMaintenance()
        receiveTask?.cancel()
        receiveTask = nil
        // Detach first, so continuations of earlier work see a stale connection.
        let connection = self.connection
        self.connection = nil
        var frames: [OutboundFrame] = []
        if let observedFrames = stopObserving() {
            observedFrames.close()
            await observedFrames.waitForAcceptedCallbacks(onWait: testHooks.onObserverDrainWait)
            frames = observedFrames.takeAll()
        }
        if let awareness {
            awareness.clearLocalState(origin: "provider destroy")
            do {
                let update = try awareness.encodeUpdate(for: [awareness.clientID])
                frames.append(OutboundFrame(
                    data: HocuspocusMessage.awareness(documentName: name, update).encoded(),
                    kind: .awareness([awareness.clientID])
                ))
            } catch {
                logger.error("failed to encode awareness removal: \(error, privacy: .public)")
            }
        }
        clearRemoteAwarenessStates()
        if let connection {
            if await !drain(connection.sender, appending: frames) {
                logger.notice("destroy gave up waiting for outbound writes after \(self.teardownDeadline, privacy: .public); closing the socket")
                connection.sender.discard()
            }
            connection.socket.close()
        }
        connectionStatusContinuation.yield(.disconnected)
        connectionStatusContinuation.finish()
        isSyncedContinuation.finish()
        authStatusContinuation.finish()
        statelessContinuation.finish()
        errorsContinuation.finish()
    }

    /// Returns false if the sender has not finished by the teardown deadline.
    private func drain(_ sender: OutboundSender, appending frames: [OutboundFrame]) async -> Bool {
        let outcome = AsyncStream.makeStream(of: Bool.self)
        // On timeout, the caller's `discard()` releases this waiter.
        Task {
            await sender.finish(appending: frames)
            outcome.continuation.yield(true)
        }
        let deadline = Task { [teardownDeadline, wait = testHooks.teardownDeadlineWait] in
            if let wait {
                await wait()
            } else {
                do { try await Task.sleep(for: teardownDeadline) } catch { return }
            }
            outcome.continuation.yield(false)
        }
        var iterator = outcome.stream.makeAsyncIterator()
        let drained = await iterator.next() ?? false
        deadline.cancel()
        outcome.continuation.finish()
        return drained
    }

    private func openWebSocket() async throws {
        guard !isDestroyed else { throw StaleConnection() }
        if connection != nil {
            dropConnection()
        }
        connectionStatusContinuation.yield(.connecting)
        let connection = makeConnection()
        self.connection = connection
        connection.socket.resume()
        connectionStatusContinuation.yield(.connected)
        try startObservingIfNeeded()
        try await sendAuthToken(for: connection.generation)

        var initialMessages: [YSyncMessage] = []
        let initialSyncEngine = makeSyncEngine { message in
            initialMessages.append(message)
        }
        try initialSyncEngine.initialSync(
            includeAwarenessQuery: false,
            includeKnownAwarenessStates: false
        )
        enqueueEngineMessages(initialMessages)
        if let awareness, try awareness.localState() != nil {
            enqueue(
                HocuspocusMessage.awareness(
                    documentName: name,
                    try awareness.encodeUpdate(for: [awareness.clientID])
                ).encoded(),
                kind: .awareness([awareness.clientID])
            )
        }

        guard !disconnectRequested else { return }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(generation: connection.generation)
        }
        startAwarenessMaintenance()
    }

    private func makeConnection() -> Connection {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let socket = webSocketFactory(url)
        let sender = OutboundSender(
            socket: socket,
            capacity: outboundCapacity,
            onSocketSend: testHooks.onSocketSend,
            onQueued: testHooks.onFrameQueued,
            onDiscard: testHooks.onFrameDiscarded,
            onFailure: { [weak self] _ in
                Task { [weak self] in
                    await self?.reconnectAfterUnexpectedDisconnect(generation: generation)
                }
            }
        )
        return Connection(generation: generation, socket: socket, sender: sender)
    }

    /// Discards queued writes and closes the current socket.
    private func dropConnection() {
        guard let connection else { return }
        self.connection = nil
        connection.sender.discard()
        connection.socket.close()
    }

    private func receiveLoop(generation: UInt64) async {
        guard let socket = connection?.socket, isCurrent(generation) else {
            return
        }
        do {
            while true {
                let data = try await socket.receive()
                // Disconnect, destroy or a newer connection may have run while
                // this receive was suspended.
                let accepted = !Task.isCancelled && isCurrent(generation)
                testHooks.onInboundFrame?(accepted)
                guard accepted else { return }
                // A received frame proves the connection is healthy, so reset the
                // backoff counter; otherwise transient drops accumulate across
                // independent outages and eventually exhaust maxRetries.
                retryAttempt = 0
                try await handle(data, generation: generation)
            }
        } catch is CancellationError {
        } catch is StaleConnection {
        } catch let error as HocuspocusProviderError {
            guard isCurrent(generation) else { return }
            logger.error("stopping without reconnecting: \(String(describing: error), privacy: .public)")
            errorsContinuation.yield(error)
            disconnect()
        } catch {
            await reconnectAfterUnexpectedDisconnect(generation: generation)
        }
    }

    private func reconnectAfterUnexpectedDisconnect(generation: UInt64) async {
        guard !disconnectRequested, isCurrent(generation) else {
            return
        }
        dropConnection()
        clearRemoteAwarenessStates()
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
            guard !disconnectRequested, !isDestroyed, connection == nil else {
                return
            }
            try await openWebSocket()
        } catch is CancellationError {
        } catch is StaleConnection {
        } catch {
            await reconnectAfterUnexpectedDisconnect(generation: connectionGeneration)
        }
    }

    private func startObservingIfNeeded() throws {
        let observedFrames: ObservedFrames
        if let existing = self.observedFrames {
            observedFrames = existing
        } else {
            observedFrames = ObservedFrames()
            self.observedFrames = observedFrames
        }
        if documentObservation == nil {
            let onForwarded = testHooks.onDocumentForwarded
            documentObservation = try document.observeUpdates { [weak self, documentObservationGate, observedFrames, name] event in
                guard observedFrames.begin() else { return }
                defer { observedFrames.end() }
                guard !documentObservationGate.isApplyingRemote else {
                    return
                }
                guard case let .update(update) = event else {
                    return
                }
                onForwarded?()
                do {
                    observedFrames.append(OutboundFrame(
                        data: try HocuspocusMessage.sync(documentName: name, YSyncMessage.update(update)).encoded(),
                        kind: .message
                    ))
                } catch {
                    logger.error("failed to encode local update: \(error, privacy: .public)")
                    return
                }
                Task { [weak self] in
                    await self?.flushObservedFrames()
                }
            }
        }
        if awarenessObservation == nil, let awareness {
            let onForwarded = testHooks.onAwarenessForwarded
            awarenessObservation = try awareness.observeUpdate { [weak self, awareness, awarenessOrigin, observedFrames, name] event in
                guard observedFrames.begin() else { return }
                defer { observedFrames.end() }
                guard case let .awarenessUpdate(change) = event else {
                    return
                }
                guard change.origin != awarenessOrigin else { return }
                let clientIDs = change.changed
                guard !clientIDs.isEmpty, let update = try? awareness.encodeUpdate(for: clientIDs) else {
                    return
                }
                observedFrames.append(OutboundFrame(
                    data: HocuspocusMessage.awareness(documentName: name, update).encoded(),
                    kind: .awareness(Set(clientIDs))
                ))
                onForwarded?()
                Task { [weak self] in
                    await self?.flushObservedFrames()
                }
            }
        }
    }

    /// Cancels native observers and returns their frame buffer, which callers
    /// close. Callbacks already running may still finish afterwards.
    private func stopObserving() -> ObservedFrames? {
        documentObservation?.cancel()
        documentObservation = nil
        awarenessObservation?.cancel()
        awarenessObservation = nil
        defer { observedFrames = nil }
        return observedFrames
    }

    private func startAwarenessMaintenance() {
        guard awarenessTask == nil, !isDestroyed, let awareness else { return }
        let id = UUID()
        awarenessTaskID = id
        let interval = awareness.timing.checkInterval
        let wait = testHooks.awarenessCheckWait
        let checked = testHooks.onAwarenessCheck
        awarenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    if let wait { try await wait() }
                    else { try await Task.sleep(for: interval) }
                } catch { return }
                let active = await self?.checkAwarenessTimeouts(id: id) == true
                checked?(active)
                guard active else { return }
            }
        }
    }

    private func stopAwarenessMaintenance() {
        awarenessTaskID = nil
        awarenessTask?.cancel()
        awarenessTask = nil
    }

    private func checkAwarenessTimeouts(id: UUID) -> Bool {
        guard !isDestroyed, awarenessTaskID == id, !Task.isCancelled else { return false }
        do {
            try awareness?.checkTimeouts()
        } catch {
            logger.error("failed to check awareness timeouts: \(error, privacy: .public)")
        }
        return true
    }

    private func handle(_ data: Data, generation: UInt64) async throws {
        let message = try HocuspocusMessage.decode(data)
        switch message {
        case let .sync(_, syncMessage):
            try await handle([syncMessage], generation: generation)
        case let .syncMessages(_, syncMessages):
            try await handle(syncMessages, generation: generation)
        case let .auth(_, auth):
            try await handle(auth, generation: generation)
        case let .awareness(_, update):
            try applyAwareness(update)
        case .queryAwareness:
            try sendKnownAwarenessStates()
        case let .stateless(_, payload):
            statelessContinuation.yield(payload)
        default:
            return
        }
    }

    private func handle(_ syncMessages: [YSyncMessage], generation: UInt64) async throws {
        var attempts = 0
        while true {
            try Task.checkCancellation()
            try ensureCurrent(generation)

            var outgoing: [YSyncMessage] = []
            let syncEngine = makeSyncEngine { message in
                outgoing.append(message)
            }
            var didSync = false
            do {
                for (index, message) in syncMessages.enumerated() {
                    let result = try syncEngine.handle(message)
                    didSync = didSync || result.didSync
                    // This hook suspends mid-frame only in tests; production uses .none.
                    await testHooks.onSyncMessageHandled?(index)
                }
            } catch YError.transactionConflict {
                await testHooks.onTransactionConflict?()
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
            try ensureCurrent(generation)
            enqueueEngineMessages(outgoing)
            if didSync {
                testHooks.onSyncStatusEmitted?()
                isSyncedContinuation.yield(true)
            }
            return
        }
    }

    private func handle(_ auth: HocuspocusAuthMessage, generation: UInt64) async throws {
        switch auth {
        case .token:
            try await sendAuthToken(for: generation)
        case let .permissionDenied(reason):
            authStatusContinuation.yield(.denied(reason: reason))
        case let .authenticated(scope):
            authStatusContinuation.yield(.authenticated(scope: scope))
        }
    }

    private func sendAuthToken(for generation: UInt64) async throws {
        let value: String
        do {
            value = try await token?() ?? ""
        } catch {
            try ensureCurrent(generation)
            throw error
        }
        // Token retrieval suspends; the connection may have been replaced.
        try ensureCurrent(generation)
        enqueue(HocuspocusMessage.auth(
            documentName: name,
            .token(value, version: Self.productName)
        ).encoded())
    }

    /// Moves frames captured by observers to the current connection. Frames
    /// observed while disconnected are dropped; reconnect sync covers document
    /// state.
    private func flushObservedFrames() {
        guard let frames = observedFrames?.takeAll(), let connection else { return }
        frames.forEach(connection.sender.enqueue)
    }

    /// Queues a frame after frames already observed, keeping observation order.
    private func enqueue(_ data: Data, kind: OutboundFrame.Kind = .message, receipt: SendReceipt? = nil) {
        flushObservedFrames()
        connection?.sender.enqueue(OutboundFrame(data: data, kind: kind, receipt: receipt))
    }

    private func sendKnownAwarenessStates() throws {
        guard awareness != nil else {
            return
        }
        var outgoing: [YSyncMessage] = []
        let syncEngine = makeSyncEngine { message in
            outgoing.append(message)
        }
        try syncEngine.sendKnownAwarenessStates()
        enqueueEngineMessages(outgoing)
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

    private func enqueueEngineMessages(_ messages: [YSyncMessage]) {
        for message in messages {
            switch message {
            case let .awareness(update, _):
                enqueue(HocuspocusMessage.awareness(documentName: name, update).encoded())
            default:
                enqueue(HocuspocusMessage.sync(documentName: name, message).encoded())
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
        let clientIDs = states.map(\.clientID).filter { $0 != awareness.clientID }
        awareness.removeStates(for: clientIDs, origin: awarenessOrigin)
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

    init(url: URL, maximumMessageSize: Int) {
        self.task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessageSize
    }

    func resume() {
        task.resume()
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EMSGSIZE) {
            throw HocuspocusProviderError.messageTooLarge(limit: task.maximumMessageSize)
        }
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
