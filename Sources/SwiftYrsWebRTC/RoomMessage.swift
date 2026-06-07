import Foundation

/// A y-webrtc room message — the `data` payload of a signaling `publish` frame.
/// Peers discover each other with `announce` and negotiate connections with
/// `signal` (which carries a `simple-peer` `PeerSignal`).
public enum RoomMessage: Equatable, Sendable {
    case announce(from: String)
    case signal(from: String, to: String, token: Double, signal: PeerSignal)

    /// The peer id this message originated from.
    var from: String {
        switch self {
        case let .announce(from), let .signal(from, _, _, _):
            return from
        }
    }

    /// The `JSONSerialization`-compatible object for this room message.
    func jsonObject() -> Any {
        switch self {
        case let .announce(from):
            return ["type": "announce", "from": from]
        case let .signal(from, to, token, signal):
            return [
                "type": "signal",
                "from": from,
                "to": to,
                "token": token,
                "signal": signal.jsonObject(),
            ]
        }
    }

    init(jsonObject: Any) throws {
        guard let object = jsonObject as? [String: Any],
              let type = object["type"] as? String,
              let from = object["from"] as? String else {
            throw WebRTCSignalingError.malformedSignal
        }
        switch type {
        case "announce":
            self = .announce(from: from)
        case "signal":
            guard let to = object["to"] as? String,
                  let token = (object["token"] as? NSNumber)?.doubleValue,
                  let signal = object["signal"] else {
                throw WebRTCSignalingError.malformedSignal
            }
            self = .signal(from: from, to: to, token: token, signal: try PeerSignal.decode(jsonObject: signal))
        default:
            throw WebRTCSignalingError.malformedSignal
        }
    }
}
