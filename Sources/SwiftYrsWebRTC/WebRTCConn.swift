import Foundation
@preconcurrency import StreamWebRTC

/// One peer-to-peer connection: an `RTCPeerConnection` plus its `negotiated:false`
/// data channel, wrapped to look like a `simple-peer` `Peer` to the rest of the
/// provider. The initiator creates the offer and the data channel; the responder
/// answers and adopts the channel libwebrtc surfaces via `didOpen`. Trickled ICE
/// is buffered until the remote description is set (ADR-0020).
///
/// All mutable state and `RTCPeerConnection` interaction is confined to a single
/// serial queue, so libwebrtc's delegate threads and the provider actor never
/// race. Outputs are delivered through `@Sendable` closures the provider wires up.
///
/// Boundary rule: libwebrtc calls are *dispatched* onto `queue` and never awaited
/// back across the provider actor during normal operation. Blocking teardown runs
/// on a separate `teardownQueue` so `close()`/`closeAndWait()` cannot deadlock
/// against delegate callbacks posted to `queue`. `destroy()` awaits `closeAndWait()`
/// so serialized E2E tests do not overlap libwebrtc teardown with the next test.
final class WebRTCConn: NSObject, @unchecked Sendable {
    let remotePeerId: String
    let initiator: Bool

    /// Emits a `simple-peer` signal to forward to the remote peer.
    var onSignal: (@Sendable (PeerSignal) -> Void)?
    /// The data channel opened (simple-peer's `connect`); time to start syncing.
    var onConnected: (@Sendable () -> Void)?
    /// A binary message arrived on the data channel.
    var onData: (@Sendable (Data) -> Void)?
    /// The connection closed or failed.
    var onClosed: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.swiftyrs.webrtc.conn")
    private let teardownQueue = DispatchQueue(label: "com.swiftyrs.webrtc.conn.teardown")
    private var connection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var remoteDescriptionSet = false
    private var pendingCandidates: [RTCIceCandidate] = []
    private var didConnect = false
    private var didClose = false

    init(
        remotePeerId: String,
        initiator: Bool,
        iceServers: [WebRTCIceServer],
        factory: RTCPeerConnectionFactory
    ) {
        self.remotePeerId = remotePeerId
        self.initiator = initiator

        let config = RTCConfiguration()
        config.iceServers = iceServers.map(\.rtcIceServer)
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(
            with: config, constraints: constraints, delegate: nil
        ) else {
            preconditionFailure("libwebrtc failed to create an RTCPeerConnection")
        }
        self.connection = connection
        super.init()
        connection.delegate = self

        if initiator {
            let dcConfig = RTCDataChannelConfiguration()
            dcConfig.isNegotiated = false
            if let channel = connection.dataChannel(forLabel: "data", configuration: dcConfig) {
                channel.delegate = self
                dataChannel = channel
            }
        }
    }

    /// Begins negotiation. The initiator creates and sends the offer; the
    /// responder waits for one.
    func start() {
        queue.async { [weak self] in
            guard let self, self.initiator, let connection = self.connection else { return }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            connection.offer(for: constraints) { [weak self] sdp, _ in
                guard let self, let sdp else { return }
                self.queue.async {
                    guard let connection = self.connection else { return }
                    connection.setLocalDescription(sdp) { [weak self] _ in
                        guard let self, let signal = PeerSignal(sessionDescription: sdp) else { return }
                        self.onSignal?(signal)
                    }
                }
            }
        }
    }

    /// Applies an inbound `simple-peer` signal from the remote peer.
    func signal(_ signal: PeerSignal) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            switch signal {
            case .offer, .answer:
                guard let description = signal.sessionDescription else { return }
                connection.setRemoteDescription(description) { [weak self] error in
                    guard let self else { return }
                    if let error { webRTCDebug("conn \(self.remotePeerId.prefix(4)) setRemoteDescription error: \(error)") }
                    self.queue.async {
                        self.remoteDescriptionSet = true
                        self.flushPendingCandidates()
                        if case .offer = signal {
                            self.createAnswer()
                        }
                    }
                }
            case .candidate:
                guard let candidate = signal.iceCandidate else { return }
                if self.remoteDescriptionSet {
                    connection.add(candidate) { error in
                        if let error { webRTCDebug("conn add candidate error: \(error)") }
                    }
                } else {
                    self.pendingCandidates.append(candidate)
                }
            case .renegotiate, .transceiverRequest:
                break
            }
        }
    }

    /// Sends a binary message over the data channel (no-op until it's open).
    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, let channel = self.dataChannel else { return }
            channel.sendData(RTCDataBuffer(data: data, isBinary: true))
        }
    }

    /// The one awaited path into the libwebrtc seam (see the boundary rule on the
    /// type). Safe to await because it is bounded by `timeout` and only polls
    /// non-blocking channel state via `resumeWhenFlushed` — it never blocks on a
    /// libwebrtc cross-thread call. Returns whether the buffer drained before the
    /// deadline.
    func sendAndFlush(_ data: Data, timeout: Duration = .milliseconds(500)) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self,
                      let channel = self.dataChannel,
                      channel.readyState == .open,
                      channel.sendData(RTCDataBuffer(data: data, isBinary: true)) else {
                    continuation.resume(returning: false)
                    return
                }
                self.resumeWhenFlushed(channel, deadline: ContinuousClock.now + timeout, continuation: continuation)
            }
        }
    }

    /// Tears the connection down, best-effort. libwebrtc's blocking close calls run
    /// on `teardownQueue` so they cannot deadlock delegate work posted to `queue`.
    /// `teardownQueue` captures `self` until close finishes so `conns.removeAll()`
    /// on the provider actor does not deallocate libwebrtc objects on the wrong thread.
    func close() {
        clearCallbacks()
        queue.async {
            let dataChannel = self.dataChannel
            let connection = self.connection
            self.dataChannel = nil
            self.connection = nil
            dataChannel?.delegate = nil
            connection?.delegate = nil
            self.teardownQueue.async {
                dataChannel?.close()
                connection?.close()
            }
        }
    }

    private func clearCallbacks() {
        onSignal = nil
        onConnected = nil
        onData = nil
        onClosed = nil
    }

    // MARK: - Queue-confined helpers

    private func createAnswer() {
        guard let connection = connection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        connection.answer(for: constraints) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            self.queue.async {
                guard let connection = self.connection else { return }
                connection.setLocalDescription(sdp) { [weak self] _ in
                    guard let self, let signal = PeerSignal(sessionDescription: sdp) else { return }
                    self.onSignal?(signal)
                }
            }
        }
    }

    private func flushPendingCandidates() {
        guard let connection = connection else { return }
        let candidates = pendingCandidates
        pendingCandidates.removeAll()
        for candidate in candidates {
            connection.add(candidate) { _ in }
        }
    }

    private func resumeWhenFlushed(
        _ channel: RTCDataChannel,
        deadline: ContinuousClock.Instant,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        if channel.bufferedAmount == 0 {
            continuation.resume(returning: true)
            return
        }
        guard ContinuousClock.now < deadline, channel.readyState == .open else {
            continuation.resume(returning: false)
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
            self.resumeWhenFlushed(channel, deadline: deadline, continuation: continuation)
        }
    }

    private func notifyClosedOnce() {
        guard !didClose else { return }
        didClose = true
        onClosed?()
    }

    private func notifyConnectedOnce() {
        guard !didConnect else { return }
        didConnect = true
        onConnected?()
    }
}

extension WebRTCConn: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onSignal?(PeerSignal(iceCandidate: candidate))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        queue.async { [weak self] in
            guard let self else { return }
            dataChannel.delegate = self
            self.dataChannel = dataChannel
            if dataChannel.readyState == .open {
                self.notifyConnectedOnce()
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        webRTCDebug("conn \(remotePeerId.prefix(4)) ICE state → \(newState.rawValue)")
        switch newState {
        case .failed, .closed:
            queue.async { [weak self] in self?.notifyClosedOnce() }
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

extension WebRTCConn: RTCDataChannelDelegate {
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onData?(buffer.data)
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        webRTCDebug("conn \(remotePeerId.prefix(4)) data channel state → \(dataChannel.readyState.rawValue)")
        switch dataChannel.readyState {
        case .open:
            queue.async { [weak self] in self?.notifyConnectedOnce() }
        case .closed:
            queue.async { [weak self] in self?.notifyClosedOnce() }
        default:
            break
        }
    }
}
