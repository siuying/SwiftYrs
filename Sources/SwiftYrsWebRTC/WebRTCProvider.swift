import Foundation
import OSLog
import SwiftYrs

let webRTCLogger = Logger(subsystem: "SwiftYrsWebRTC", category: "provider")

private let webRTCDebugEnabled = ProcessInfo.processInfo.environment["WEBRTC_DEBUG"] != nil

func webRTCDebug(_ message: @autoclosure () -> String) {
    guard webRTCDebugEnabled else { return }
    FileHandle.standardError.write(Data("[webrtc] \(message())\n".utf8))
}

/// A WebRTC transport for a `YDoc`, interoperable with browser `y-webrtc` peers.
/// Peers discover each other through one or more signaling servers and then sync
/// the document directly over a mesh of WebRTC data channels. The provider
/// borrows y-webrtc's vocabulary but is a Swift `actor` with an explicit async
/// lifecycle — see ADR-0021 (shape) and ADR-0020 (the simple-peer seam).
public actor WebRTCProvider {
    public struct Options: Sendable {
        public var password: String?
        public var awareness: YAwareness?
        public var maxConns: Int
        public var iceServers: [WebRTCIceServer]
        public var maxRetries: Int
        public var initialDelay: Duration
        public var maxDelay: Duration

        public init(
            password: String? = nil,
            awareness: YAwareness? = nil,
            // Randomized default mirrors y-webrtc's `maxConns`: a per-peer jitter
            // so peers in a large room don't all hit the connection cap at the
            // same size and deterministically reject the same inbound peers.
            maxConns: Int = 20 + Int.random(in: 0..<15),
            iceServers: [WebRTCIceServer] = .defaultSTUN,
            maxRetries: Int = .max,
            initialDelay: Duration = .seconds(1),
            maxDelay: Duration = .seconds(30)
        ) {
            self.password = password
            self.awareness = awareness
            self.maxConns = maxConns
            self.iceServers = iceServers
            self.maxRetries = maxRetries
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
        }
    }

    public struct PeersEvent: Sendable {
        public let added: [String]
        public let removed: [String]
        public let webrtcPeers: [String]
    }

    public enum WebRTCConnectionStatus: Sendable {
        case connecting
        case connected
        case disconnected
    }

    public let roomName: String
    public let doc: YDoc
    public let awareness: YAwareness

    public nonisolated let status: AsyncStream<WebRTCConnectionStatus>
    public nonisolated let synced: AsyncStream<Bool>
    public nonisolated let peers: AsyncStream<PeersEvent>

    private let signalingURLs: [URL]
    private let options: Options
    private let peerConnectionFactory = WebRTCFactory.makePeerConnectionFactory()
    private let ownsAwareness: Bool
    private let peerId = UUID().uuidString.lowercased()
    private let signalingCipher: SignalingCipher?

    private let statusContinuation: AsyncStream<WebRTCConnectionStatus>.Continuation
    private let syncedContinuation: AsyncStream<Bool>.Continuation
    private let peersContinuation: AsyncStream<PeersEvent>.Continuation

    private var signalingConnections: [SignalingConnection] = []
    private var openSignalingConnections: Set<ObjectIdentifier> = []
    private var conns: [String: PeerRecord] = [:]
    private var documentObservation: Observation?
    private var awarenessObservation: Observation?
    private var reannounceTask: Task<Void, Never>?
    private var started = false
    private var connectionStatus: WebRTCConnectionStatus = .disconnected
    private var lastSynced = false

    private final class PeerRecord: @unchecked Sendable {
        let conn: WebRTCConn
        var glareToken: Double?
        var synced = false
        var channelOpen = false
        var awarenessClientIDs: Set<UInt64> = []
        init(conn: WebRTCConn) { self.conn = conn }
    }

    public init(_ roomName: String, doc: YDoc, signaling: [URL], options: Options = .init()) {
        self.roomName = roomName
        self.doc = doc
        self.signalingURLs = signaling
        self.options = options
        if let password = options.password {
            guard let cipher = try? SignalingCipher(password: password, roomName: roomName) else {
                preconditionFailure("Failed to derive WebRTC signaling password key")
            }
            self.signalingCipher = cipher
        } else {
            self.signalingCipher = nil
        }
        if let awareness = options.awareness {
            self.awareness = awareness
            self.ownsAwareness = false
        } else {
            self.awareness = YAwareness(document: doc)
            self.ownsAwareness = true
        }

        let statusPair = AsyncStream.makeStream(of: WebRTCConnectionStatus.self)
        status = statusPair.stream
        statusContinuation = statusPair.continuation
        let syncedPair = AsyncStream.makeStream(of: Bool.self)
        synced = syncedPair.stream
        syncedContinuation = syncedPair.continuation
        let peersPair = AsyncStream.makeStream(of: PeersEvent.self)
        peers = peersPair.stream
        peersContinuation = peersPair.continuation
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        guard !started else { return }
        started = true
        emitStatus(.connecting)
        try startObserving()
        signalingConnections = signalingURLs.map { url in
            SignalingConnection(
                url: url,
                initialDelay: options.initialDelay,
                maxDelay: options.maxDelay,
                maxRetries: options.maxRetries,
                cipher: signalingCipher,
                onOpen: { [weak self] connection in await self?.signalingDidOpen(connection) },
                onClose: { [weak self] connection in await self?.signalingDidClose(connection) },
                onMessage: { [weak self] message in await self?.handleSignaling(message) }
            )
        }
        for connection in signalingConnections {
            await connection.start()
        }
        startReannounceLoop()
    }

    /// Stops the provider while leaving its event streams open, so a later
    /// `connect()` can resume. Signaling is stopped fire-and-forget; for a fully
    /// awaited, terminal teardown use `destroy()`.
    public func disconnect() {
        guard started else { return }
        beginTearDown()
        for connection in signalingConnections {
            Task { await connection.stop() }
        }
        finishTearDown()
    }

    /// Terminal teardown: clears owned awareness, awaits signaling stop before
    /// closing peers, then finishes the event streams so iterators end.
    public func destroy() async {
        guard started else { return }
        if ownsAwareness {
            await clearOwnedAwareness()
        }
        beginTearDown()
        // Stop signaling before closing peer connections so the receive loop
        // cannot dispatch announces/signals into a provider that is tearing down.
        for connection in signalingConnections {
            await connection.stop()
        }
        finishTearDown()
        statusContinuation.finish()
        syncedContinuation.finish()
        peersContinuation.finish()
    }

    /// Marks the provider stopped and halts the reannounce loop. Runs before
    /// signaling is stopped so no further announces are queued; peers and
    /// observations are torn down afterwards in `finishTearDown`.
    private func beginTearDown() {
        started = false
        reannounceTask?.cancel()
        reannounceTask = nil
    }

    /// Releases everything that does not need to outlive a stop: signaling
    /// bookkeeping, peer connections, observations, and synced/status state.
    private func finishTearDown() {
        signalingConnections.removeAll()
        openSignalingConnections.removeAll()
        documentObservation?.cancel()
        documentObservation = nil
        awarenessObservation?.cancel()
        awarenessObservation = nil
        for record in conns.values {
            record.conn.close()
        }
        conns.removeAll()
        emitStatus(.disconnected)
        emitSynced(false)
    }

    public var connected: Bool {
        connectionStatus == .connected
    }

    /// Aggregate signaling state across every configured server: `.connected` if
    /// any server's socket is open, `.connecting` while the provider is started
    /// but no server is open yet (all connecting/retrying), and `.disconnected`
    /// before `connect()` or after `disconnect()`/`destroy()`. Maintained by
    /// `recomputeSignalingStatus` as individual server sockets open and close.
    public var signalingStatus: WebRTCConnectionStatus {
        connectionStatus
    }

    public var connectedPeers: Set<String> {
        Set(conns.filter { $0.value.channelOpen }.keys)
    }

    // MARK: - Signaling

    private func signalingDidOpen(_ connection: SignalingConnection) async {
        webRTCDebug("\(peerId.prefix(4)) signaling open → subscribe+announce")
        openSignalingConnections.insert(ObjectIdentifier(connection))
        await connection.send(SignalingCodec.subscribe(topics: [roomName]))
        await sendRoomMessage(.announce(from: peerId), on: connection)
        recomputeSignalingStatus()
    }

    private func signalingDidClose(_ connection: SignalingConnection) {
        openSignalingConnections.remove(ObjectIdentifier(connection))
        recomputeSignalingStatus()
    }

    private func handleSignaling(_ message: IncomingSignalingMessage) async {
        guard started else { return }
        guard case let .publish(topic, data) = message, topic == roomName else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let roomMessage = try? RoomMessage(jsonObject: object) else { return }
        guard roomMessage.from != peerId else { return }
        switch roomMessage {
        case let .announce(from):
            webRTCDebug("\(peerId.prefix(4)) recv announce from \(from.prefix(4))")
            await handleAnnounce(from: from)
        case let .signal(from, to, token, signal):
            guard to == peerId else { return }
            webRTCDebug("\(peerId.prefix(4)) recv signal \(signalKind(signal)) from \(from.prefix(4))")
            handleSignal(from: from, token: token, signal: signal)
        }
    }

    private func handleAnnounce(from: String) async {
        guard started else { return }
        guard conns[from] == nil else { return }
        guard conns.count < options.maxConns else {
            // At capacity we cannot initiate, but peers still need our announce so
            // they can open an inbound WebRTC connection. Re-announce on every
            // remote announce so a missed frame does not stall until the periodic loop.
            webRTCDebug("\(peerId.prefix(4)) at capacity, re-announcing for inbound \(from.prefix(4))")
            await announceToOpenSignalingConnections()
            return
        }
        let record = makeConn(remotePeerId: from, initiator: true)
        record.conn.start()
        emitPeers(added: [from], removed: [])
    }

    private func handleSignal(from: String, token: Double, signal: PeerSignal) {
        guard started else { return }
        if case .offer = signal, let existing = conns[from] {
            if GlareResolver.shouldRejectIncomingOffer(localToken: existing.glareToken, remoteToken: token) {
                return
            }
            conns[from] = nil
            existing.conn.close()
        }
        if case .answer = signal {
            conns[from]?.glareToken = nil
        }
        let isNew = conns[from] == nil
        let record = conns[from] ?? makeConn(remotePeerId: from, initiator: false)
        record.conn.signal(signal)
        if isNew {
            emitPeers(added: [from], removed: [])
        }
    }

    private func publishSignal(to remotePeerId: String, token: Double, signal: PeerSignal) async {
        let message = RoomMessage.signal(from: peerId, to: remotePeerId, token: token, signal: signal)
        guard let frame = encodePublish(message) else { return }
        for connection in signalingConnections {
            await connection.send(frame)
        }
    }

    private func sendRoomMessage(_ message: RoomMessage, on connection: SignalingConnection) async {
        guard let frame = encodePublish(message) else { return }
        await connection.send(frame)
    }

    /// Encodes a room message as a signaling `publish` frame. A failure here is
    /// an encoding bug rather than a transient network drop, so it is logged
    /// rather than silently swallowed.
    private func encodePublish(_ message: RoomMessage) -> Data? {
        do {
            return try SignalingCodec.publish(
                topic: roomName, data: message.jsonObject(), cipher: signalingCipher
            )
        } catch {
            webRTCLogger.error("failed to encode signaling publish frame: \(error, privacy: .public)")
            return nil
        }
    }

    private func startReannounceLoop(interval: Duration = .seconds(30)) {
        reannounceTask?.cancel()
        reannounceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.announceToOpenSignalingConnections()
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
            }
        }
    }

    private func announceToOpenSignalingConnections() async {
        for connection in signalingConnections where openSignalingConnections.contains(ObjectIdentifier(connection)) {
            await sendRoomMessage(.announce(from: peerId), on: connection)
        }
    }

    // MARK: - Peer connections

    private func makeConn(remotePeerId: String, initiator: Bool) -> PeerRecord {
        let conn = WebRTCConn(
            remotePeerId: remotePeerId,
            initiator: initiator,
            iceServers: options.iceServers,
            factory: peerConnectionFactory
        )
        let record = PeerRecord(conn: conn)
        conns[remotePeerId] = record
        conn.onSignal = { [weak self, weak record] signal in
            Task { await self?.peerEmittedSignal(peerId: remotePeerId, record: record, signal: signal) }
        }
        conn.onConnected = { [weak self, weak record] in
            Task { await self?.peerConnected(peerId: remotePeerId, record: record) }
        }
        conn.onData = { [weak self, weak record] data in
            Task { await self?.peerReceivedData(peerId: remotePeerId, record: record, data: data) }
        }
        conn.onClosed = { [weak self, weak record] in
            Task { await self?.peerClosed(peerId: remotePeerId, record: record) }
        }
        return record
    }

    private func peerEmittedSignal(peerId remotePeerId: String, record: PeerRecord?, signal: PeerSignal) async {
        guard let record, let current = conns[remotePeerId], current === record else { return }
        let token = current.glareToken ?? newGlareToken()
        current.glareToken = token
        webRTCDebug("\(peerId.prefix(4)) emit signal \(signalKind(signal)) → \(remotePeerId.prefix(4))")
        await publishSignal(to: remotePeerId, token: token, signal: signal)
    }

    private func peerConnected(peerId remotePeerId: String, record: PeerRecord?) {
        guard let record, let current = conns[remotePeerId], current === record else { return }
        webRTCDebug("\(peerId.prefix(4)) data channel OPEN with \(remotePeerId.prefix(4))")
        current.channelOpen = true
        sendInitialSync(to: current)
        recomputeSynced()
    }

    private func peerReceivedData(peerId remotePeerId: String, record: PeerRecord?, data: Data) {
        guard let record, let current = conns[remotePeerId], current === record else { return }
        guard let messages = try? YSyncMessage.decodePayload(data) else { return }
        for message in messages {
            handle(message, from: current)
        }
    }

    private func peerClosed(peerId remotePeerId: String, record: PeerRecord?) {
        guard let record, let current = conns[remotePeerId], current === record else { return }
        // Dispose through close() even though the peer already closed: blocking
        // libwebrtc teardown runs on the conn's teardownQueue (after properties are
        // nilled on `queue`), so dropping `current` here does not release those
        // objects on the provider-actor thread. See WebRTCConn.close.
        current.conn.close()
        conns[remotePeerId] = nil
        removeAwarenessStatesIntroduced(by: current)
        emitPeers(added: [], removed: [remotePeerId])
        recomputeSynced()
    }

    private func sendInitialSync(to record: PeerRecord) {
        do {
            let syncEngine = makeSyncEngine(for: record)
            try syncEngine.initialSync()
        } catch {
            webRTCLogger.error("failed to send initial sync to peer: \(error, privacy: .public)")
        }
    }

    private func handle(_ message: YSyncMessage, from record: PeerRecord) {
        do {
            let result = try makeSyncEngine(for: record).handle(message)
            if result.didSync {
                record.synced = true
                recomputeSynced()
            }
            record.awarenessClientIDs.formUnion(result.awarenessAddedClientIDs)
            record.awarenessClientIDs.subtract(result.awarenessRemovedClientIDs)
        } catch {
            webRTCLogger.error("failed to handle sync message from peer: \(error, privacy: .public)")
        }
    }

    private func makeSyncEngine(for record: PeerRecord) -> YSyncEngine {
        YSyncEngine(
            doc: doc,
            awareness: awareness,
            send: { message in
                record.conn.send(message.payload)
            },
            applyUpdate: { [doc] update in
                // Mesh gossip: applying a remote update fires the document
                // observer, which re-broadcasts it to every peer. CRDT
                // idempotency terminates the flood, so no echo gate is needed.
                try doc.write(origin: "SwiftYrsWebRTC") { transaction in
                    try transaction.apply(update)
                }
            },
            applyAwarenessUpdate: { [awareness] update in
                try awareness.applyUpdate(update)
            }
        )
    }

    private func removeAwarenessStatesIntroduced(by record: PeerRecord) {
        for clientID in record.awarenessClientIDs {
            awareness.removeState(for: clientID)
        }
        record.awarenessClientIDs.removeAll()
    }

    // MARK: - Observation & broadcast

    private func startObserving() throws {
        if documentObservation == nil {
            documentObservation = try doc.observeUpdates { [weak self] event in
                guard case let .update(update) = event else { return }
                Task { [weak self] in await self?.broadcastDocumentUpdate(update) }
            }
        }
        if awarenessObservation == nil {
            awarenessObservation = try awareness.observeUpdate { [weak self, awareness] event in
                guard case let .awarenessUpdate(change) = event else { return }
                let clientIDs = change.changed
                guard !clientIDs.isEmpty, let update = try? awareness.encodeUpdate(for: clientIDs) else { return }
                Task { [weak self] in await self?.broadcastAwarenessUpdate(update) }
            }
        }
    }

    private func broadcastDocumentUpdate(_ update: YUpdate) {
        guard let payload = try? YSyncMessage.update(update).payload else { return }
        broadcast(payload)
    }

    private func broadcastAwarenessUpdate(_ update: YAwarenessUpdate) {
        guard let payload = try? YSyncMessage.awareness(update).payload else { return }
        broadcast(payload)
    }

    private func clearOwnedAwareness() async {
        let clientID = awareness.clientID
        awareness.clearLocalState()
        guard let update = try? awareness.encodeUpdate(for: [clientID]),
              let payload = try? YSyncMessage.awareness(update).payload else { return }
        await broadcastAndFlush(payload)
    }

    private func broadcastAndFlush(_ payload: Data) async {
        let openConns = conns.values.compactMap { record in
            record.channelOpen ? record.conn : nil
        }
        for conn in openConns {
            _ = await conn.sendAndFlush(payload)
        }
    }

    private func broadcast(_ payload: Data) {
        for record in conns.values where record.channelOpen {
            record.conn.send(payload)
        }
    }

    // MARK: - State

    private func recomputeSynced() {
        let openPeers = conns.values.filter(\.channelOpen)
        let synced = !openPeers.isEmpty && openPeers.allSatisfy(\.synced)
        emitSynced(synced)
    }

    private func emitSynced(_ value: Bool) {
        guard value != lastSynced else { return }
        lastSynced = value
        syncedContinuation.yield(value)
    }

    private func emitStatus(_ status: WebRTCConnectionStatus) {
        connectionStatus = status
        statusContinuation.yield(status)
    }

    private func recomputeSignalingStatus() {
        let status: WebRTCConnectionStatus
        if !openSignalingConnections.isEmpty {
            status = .connected
        } else if started {
            status = .connecting
        } else {
            status = .disconnected
        }
        guard status != connectionStatus else { return }
        emitStatus(status)
    }

    private func emitPeers(added: [String], removed: [String]) {
        peersContinuation.yield(PeersEvent(
            added: added, removed: removed, webrtcPeers: Array(conns.keys)
        ))
    }

    private nonisolated func signalKind(_ signal: PeerSignal) -> String {
        switch signal {
        case .offer: return "offer"
        case .answer: return "answer"
        case .candidate: return "candidate"
        case .renegotiate: return "renegotiate"
        case .transceiverRequest: return "transceiverRequest"
        }
    }

    private func newGlareToken() -> Double {
        Date().timeIntervalSince1970 * 1000 + Double.random(in: 0..<1)
    }
}
