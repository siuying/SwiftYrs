import Foundation

/// A decoded inbound signaling frame. Only `publish` and `pong` are acted on;
/// any other frame is `ignored` (the signaling server may send control frames
/// we don't care about). The `publish` payload is carried as raw JSON `Data`
/// (rather than a non-`Sendable` `Any`) so frames can cross into the actor.
enum IncomingSignalingMessage: Sendable, Equatable {
    case publish(topic: String, data: Data)
    case pong
    case ignored
}

/// Encodes and decodes the y-webrtc signaling wire frames exchanged with the
/// signaling server (a pub/sub relay over WebSocket). Frames are JSON.
enum SignalingCodec {
    static func subscribe(topics: [String]) -> Data {
        encode(["type": "subscribe", "topics": topics])
    }

    static func unsubscribe(topics: [String]) -> Data {
        encode(["type": "unsubscribe", "topics": topics])
    }

    static func publish(topic: String, data: Any, cipher: SignalingCipher? = nil) throws -> Data {
        let payload: Any = if let cipher {
            try cipher.encryptJSON(data)
        } else {
            data
        }
        return encode(["type": "publish", "topic": topic, "data": payload])
    }

    static func ping() -> Data {
        encode(["type": "ping"])
    }

    static func decode(_ data: Data, cipher: SignalingCipher? = nil) throws -> IncomingSignalingMessage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            throw WebRTCSignalingError.malformedSignal
        }
        switch type {
        case "publish":
            guard let topic = object["topic"] as? String, let payload = object["data"] else {
                throw WebRTCSignalingError.malformedSignal
            }
            let decodedPayload: Any
            if let cipher {
                guard let encrypted = payload as? String else {
                    throw WebRTCSignalingError.malformedSignal
                }
                decodedPayload = try cipher.decryptJSON(encrypted)
            } else {
                decodedPayload = payload
            }
            let payloadData = try JSONSerialization.data(withJSONObject: decodedPayload, options: [.fragmentsAllowed])
            return .publish(topic: topic, data: payloadData)
        case "pong":
            return .pong
        default:
            return .ignored
        }
    }

    private static func encode(_ object: [String: Any]) -> Data {
        // These objects are constructed internally from known-encodable values.
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
