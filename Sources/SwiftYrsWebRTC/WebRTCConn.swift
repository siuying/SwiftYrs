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
    private let connection: RTCPeerConnection
    private var dataChannel: RTCDataChannel?
    private var remoteDescriptionSet = false
    private var pendingCandidates: [RTCIceCandidate] = []
    private var didClose = false

    init(remotePeerId: String, initiator: Bool, iceServers: [WebRTCIceServer]) {
        self.remotePeerId = remotePeerId
        self.initiator = initiator

        let config = RTCConfiguration()
        config.iceServers = iceServers.map(\.rtcIceServer)
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = WebRTCFactory.shared.peerConnection(
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
            guard let self, self.initiator else { return }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            self.connection.offer(for: constraints) { [weak self] sdp, _ in
                guard let self, let sdp else { return }
                self.queue.async {
                    self.connection.setLocalDescription(sdp) { [weak self] _ in
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
            guard let self else { return }
            switch signal {
            case .offer, .answer:
                guard let description = signal.sessionDescription else { return }
                self.connection.setRemoteDescription(description) { [weak self] error in
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
                    self.connection.add(candidate) { error in
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

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.dataChannel?.close()
            self.connection.close()
        }
    }

    // MARK: - Queue-confined helpers

    private func createAnswer() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        connection.answer(for: constraints) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            self.queue.async {
                self.connection.setLocalDescription(sdp) { [weak self] _ in
                    guard let self, let signal = PeerSignal(sessionDescription: sdp) else { return }
                    self.onSignal?(signal)
                }
            }
        }
    }

    private func flushPendingCandidates() {
        let candidates = pendingCandidates
        pendingCandidates.removeAll()
        for candidate in candidates {
            connection.add(candidate) { _ in }
        }
    }

    private func notifyClosedOnce() {
        guard !didClose else { return }
        didClose = true
        onClosed?()
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
            onConnected?()
        case .closed:
            queue.async { [weak self] in self?.notifyClosedOnce() }
        default:
            break
        }
    }
}
