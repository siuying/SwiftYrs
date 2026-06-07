import StreamWebRTC

/// The libwebrtc side of the simple-peer seam (ADR-0020): translate libwebrtc's
/// `RTCSessionDescription` / `RTCIceCandidate` into `PeerSignal` shapes and back,
/// so a Swift peer's offers, answers and trickled ICE look like simple-peer's to
/// a browser, and vice versa.
extension PeerSignal {
    init?(sessionDescription: RTCSessionDescription) {
        switch sessionDescription.type {
        case .offer:
            self = .offer(sdp: sessionDescription.sdp)
        case .answer, .prAnswer:
            self = .answer(sdp: sessionDescription.sdp)
        case .rollback:
            return nil
        @unknown default:
            return nil
        }
    }

    init(iceCandidate: RTCIceCandidate) {
        self = .candidate(IceCandidate(
            candidate: iceCandidate.sdp,
            sdpMid: iceCandidate.sdpMid,
            sdpMLineIndex: iceCandidate.sdpMLineIndex
        ))
    }

    var sessionDescription: RTCSessionDescription? {
        switch self {
        case let .offer(sdp):
            return RTCSessionDescription(type: .offer, sdp: sdp)
        case let .answer(sdp):
            return RTCSessionDescription(type: .answer, sdp: sdp)
        default:
            return nil
        }
    }

    var iceCandidate: RTCIceCandidate? {
        guard case let .candidate(candidate) = self else {
            return nil
        }
        return RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
            sdpMid: candidate.sdpMid
        )
    }
}
