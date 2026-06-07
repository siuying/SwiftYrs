import Foundation
import SwiftYrs

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
    private let ownsAwareness: Bool
    private let peerId = UUID().uuidString.lowercased()

    private let statusContinuation: AsyncStream<WebRTCConnectionStatus>.Continuation
    private let syncedContinuation: AsyncStream<Bool>.Continuation
    private let peersContinuation: AsyncStream<PeersEvent>.Continuation

    private var signalingConnections: [SignalingConnection] = []
    private var conns: [String: PeerRecord] = [:]
    private var documentObservation: Observation?
    private var awarenessObservation: Observation?
    private var started = false
    private var connectionStatus: WebRTCConnectionStatus = .disconnected
    private var lastSynced = false

    private final class PeerRecord: @unchecked Sendable {
        let conn: WebRTCConn
        var glareToken: Double?
        var synced = false
        var channelOpen = false
        init(conn: WebRTCConn) { self.conn = conn }
    }

    public init(_ roomName: String, doc: YDoc, signaling: [URL], options: Options = .init()) {
        self.roomName = roomName
        self.doc = doc
        self.signalingURLs = signaling
        self.options = options
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
                onOpen: { [weak self] connection in await self?.signalingDidOpen(connection) },
                onMessage: { [weak self] message in await self?.handleSignaling(message) }
            )
        }
        for connection in signalingConnections {
            await connection.start()
        }
    }

    public func disconnect() {
        guard started else { return }
        started = false
        for connection in signalingConnections {
            Task { await connection.stop() }
        }
        signalingConnections.removeAll()
        for record in conns.values {
            record.conn.close()
        }
        conns.removeAll()
        documentObservation?.cancel()
        documentObservation = nil
        awarenessObservation?.cancel()
        awarenessObservation = nil
        emitStatus(.disconnected)
        emitSynced(false)
    }

    public func destroy() async {
        if ownsAwareness {
            await clearOwnedAwareness()
        }
        await disconnectAndWait()
        statusContinuation.finish()
        syncedContinuation.finish()
        peersContinuation.finish()
    }

    public var connected: Bool {
        connectionStatus == .connected
    }

    public var connectedPeers: Set<String> {
        Set(conns.filter { $0.value.channelOpen }.keys)
    }

    private func disconnectAndWait() async {
        guard started else { return }
        started = false
        let signalingConnections = signalingConnections
        self.signalingConnections.removeAll()
        for connection in signalingConnections {
            await connection.stop()
        }
        let records = Array(conns.values)
        conns.removeAll()
        for record in records {
            await record.conn.closeAndWait()
        }
        documentObservation?.cancel()
        documentObservation = nil
        awarenessObservation?.cancel()
        awarenessObservation = nil
        emitStatus(.disconnected)
        emitSynced(false)
    }

    // MARK: - Signaling

    private func signalingDidOpen(_ connection: SignalingConnection) async {
        webRTCDebug("\(peerId.prefix(4)) signaling open → subscribe+announce")
        await connection.send(SignalingCodec.subscribe(topics: [roomName]))
        if conns.count < options.maxConns {
            await connection.send(SignalingCodec.publish(
                topic: roomName, data: RoomMessage.announce(from: peerId).jsonObject()
            ))
        }
        if connectionStatus != .connected {
            emitStatus(.connected)
        }
    }

    private func handleSignaling(_ message: IncomingSignalingMessage) async {
        guard case let .publish(topic, data) = message, topic == roomName else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let roomMessage = try? RoomMessage(jsonObject: object) else { return }
        guard roomMessage.from != peerId else { return }
        switch roomMessage {
        case let .announce(from):
            webRTCDebug("\(peerId.prefix(4)) recv announce from \(from.prefix(4))")
            handleAnnounce(from: from)
        case let .signal(from, to, token, signal):
            guard to == peerId else { return }
            webRTCDebug("\(peerId.prefix(4)) recv signal \(signalKind(signal)) from \(from.prefix(4))")
            handleSignal(from: from, token: token, signal: signal)
        }
    }

    private func handleAnnounce(from: String) {
        guard conns[from] == nil, conns.count < options.maxConns else { return }
        let record = makeConn(remotePeerId: from, initiator: true)
        record.conn.start()
        emitPeers(added: [from], removed: [])
    }

    private func handleSignal(from: String, token: Double, signal: PeerSignal) {
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
        let frame = SignalingCodec.publish(topic: roomName, data: message.jsonObject())
        for connection in signalingConnections {
            await connection.send(frame)
        }
    }

    // MARK: - Peer connections

    private func makeConn(remotePeerId: String, initiator: Bool) -> PeerRecord {
        let conn = WebRTCConn(remotePeerId: remotePeerId, initiator: initiator, iceServers: options.iceServers)
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
        conns[remotePeerId] = nil
        emitPeers(added: [], removed: [remotePeerId])
        recomputeSynced()
    }

    private func sendInitialSync(to record: PeerRecord) {
        do {
            let syncStep1 = try YSyncMessage.syncStep1(doc.stateVector())
            record.conn.send(syncStep1.payload)
            let clientIDs = try awareness.states().map(\.clientID)
            if !clientIDs.isEmpty {
                let update = try awareness.encodeUpdate(for: clientIDs)
                record.conn.send(try YSyncMessage.awareness(update).payload)
            }
        } catch {}
    }

    private func handle(_ message: YSyncMessage, from record: PeerRecord) {
        do {
            switch message {
            case let .syncStep1(stateVector, _):
                let update = try doc.encodeStateAsUpdateV1(from: stateVector)
                record.conn.send(try YSyncMessage.syncStep2(update).payload)
            case let .syncStep2(update, _):
                try applyRemote(update)
                record.synced = true
                recomputeSynced()
            case let .update(update, _):
                try applyRemote(update)
            case let .awareness(update, _):
                try awareness.applyUpdate(update)
            case .awarenessQuery:
                let clientIDs = try awareness.states().map(\.clientID)
                if !clientIDs.isEmpty {
                    let update = try awareness.encodeUpdate(for: clientIDs)
                    record.conn.send(try YSyncMessage.awareness(update).payload)
                }
            default:
                break
            }
        } catch {}
    }

    private func applyRemote(_ update: YUpdate) throws {
        // Mesh gossip: applying a remote update fires the document observer, which
        // re-broadcasts it to every peer. CRDT idempotency (a redundant apply
        // produces no observer event) terminates the flood, so no echo gate is
        // needed — unlike the single-peer HocuspocusProvider.
        try doc.write(origin: "SwiftYrsWebRTC") { transaction in
            try transaction.apply(update)
        }
    }

    // MARK: - Observation & broadcast

    private func startObserving() throws {
        if documentObservation == nil {
            documentObservation = try doc.observeUpdates { [weak self] event in
                guard let update = Self.update(from: event) else { return }
                Task { await self?.broadcastDocumentUpdate(update) }
            }
        }
        if awarenessObservation == nil {
            awarenessObservation = try awareness.observeUpdate { [weak self, awareness] event in
                let clientIDs = Self.awarenessClientIDs(from: event)
                guard !clientIDs.isEmpty, let update = try? awareness.encodeUpdate(for: clientIDs) else { return }
                Task { await self?.broadcastAwarenessUpdate(update) }
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

    private nonisolated static func update(from event: YObservationEvent) -> YUpdate? {
        guard event.kind == "updateV1" else { return nil }
        let bytes = event.array("updateV1").compactMap { value -> UInt8? in
            (value as? UInt8) ?? (value as? NSNumber)?.uint8Value
        }
        guard !bytes.isEmpty else { return nil }
        return .v1(Data(bytes))
    }

    private nonisolated static func awarenessClientIDs(from event: YObservationEvent) -> [UInt64] {
        (event.array("added") + event.array("updated") + event.array("removed")).compactMap { value in
            (value as? UInt64) ?? (value as? NSNumber)?.uint64Value
        }
    }
}
