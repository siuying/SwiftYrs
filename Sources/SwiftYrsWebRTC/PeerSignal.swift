import Foundation

/// A `simple-peer` signaling object, the payload browsers exchange inside a
/// y-webrtc `signal` room message. We build on raw libwebrtc and translate its
/// SDP and trickled ICE into these shapes (and back) so a Swift peer interops
/// with browser `simple-peer` peers — see ADR-0020.
public enum PeerSignal: Equatable, Sendable {
    case offer(sdp: String)
    case answer(sdp: String)
    case candidate(IceCandidate)
    /// `simple-peer` emits these; y-webrtc's data-channel-only connection ignores them.
    case renegotiate
    case transceiverRequest

    public struct IceCandidate: Equatable, Sendable, Codable {
        public let candidate: String
        public let sdpMid: String?
        public let sdpMLineIndex: Int32?

        public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?) {
            self.candidate = candidate
            self.sdpMid = sdpMid
            self.sdpMLineIndex = sdpMLineIndex
        }
    }

    /// The `simple-peer` JSON object for this signal, suitable for nesting in a
    /// `signal` room message (`JSONSerialization`-compatible Foundation value).
    func jsonObject() -> Any {
        switch self {
        case let .offer(sdp):
            return ["type": "offer", "sdp": sdp]
        case let .answer(sdp):
            return ["type": "answer", "sdp": sdp]
        case let .candidate(candidate):
            var inner: [String: Any] = ["candidate": candidate.candidate]
            inner["sdpMid"] = candidate.sdpMid
            inner["sdpMLineIndex"] = candidate.sdpMLineIndex.map { Int($0) }
            return ["type": "candidate", "candidate": inner]
        case .renegotiate:
            return ["type": "renegotiate"]
        case .transceiverRequest:
            return ["type": "transceiverRequest"]
        }
    }

    public static func decode(from data: Data) throws -> PeerSignal {
        let object = try JSONSerialization.jsonObject(with: data)
        return try decode(jsonObject: object)
    }

    static func decode(jsonObject: Any) throws -> PeerSignal {
        guard let object = jsonObject as? [String: Any],
              let type = object["type"] as? String else {
            throw WebRTCSignalingError.malformedSignal
        }
        switch type {
        case "offer":
            return .offer(sdp: try string(object["sdp"]))
        case "answer":
            return .answer(sdp: try string(object["sdp"]))
        case "candidate":
            guard let candidate = object["candidate"] as? [String: Any] else {
                throw WebRTCSignalingError.malformedSignal
            }
            return .candidate(IceCandidate(
                candidate: try string(candidate["candidate"]),
                sdpMid: candidate["sdpMid"] as? String,
                sdpMLineIndex: (candidate["sdpMLineIndex"] as? NSNumber)?.int32Value
            ))
        case "renegotiate":
            return .renegotiate
        case "transceiverRequest":
            return .transceiverRequest
        default:
            throw WebRTCSignalingError.malformedSignal
        }
    }

    private static func string(_ value: Any?) throws -> String {
        guard let value = value as? String else {
            throw WebRTCSignalingError.malformedSignal
        }
        return value
    }
}

public enum WebRTCSignalingError: Error, Equatable {
    case malformedSignal
}
