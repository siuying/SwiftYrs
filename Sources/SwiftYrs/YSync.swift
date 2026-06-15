import Foundation
import YrsBridgeFFI

public enum YSyncMessage: Equatable {
    case syncStep1(YStateVector, payload: Data)
    case syncStep2(YUpdate, payload: Data)
    case update(YUpdate, payload: Data)
    case awareness(YAwarenessUpdate, payload: Data)
    case awarenessQuery(payload: Data)
    case auth(reason: String?, payload: Data)
    case custom(tag: UInt8, data: Data, payload: Data)

    public var payload: Data {
        switch self {
        case let .syncStep1(_, payload),
             let .syncStep2(_, payload),
             let .update(_, payload),
             let .awareness(_, payload),
             let .awarenessQuery(payload),
             let .auth(_, payload),
             let .custom(_, _, payload):
            payload
        }
    }

    public static func syncStep1(_ stateVector: YStateVector) throws -> YSyncMessage {
        let payload = try encodeMessage(stateVector.data, yrs_bridge_sync_message_sync_step1)
        return .syncStep1(stateVector, payload: payload)
    }

    public static func syncStep2(_ update: YUpdate) throws -> YSyncMessage {
        let payload = try encodeMessage(update.data, yrs_bridge_sync_message_sync_step2)
        return .syncStep2(update, payload: payload)
    }

    public static func update(_ update: YUpdate) throws -> YSyncMessage {
        let payload = try encodeMessage(update.data, yrs_bridge_sync_message_update)
        return .update(update, payload: payload)
    }

    public static func awareness(_ update: YAwarenessUpdate) throws -> YSyncMessage {
        let payload = try encodeMessage(update.data, yrs_bridge_sync_message_awareness)
        return .awareness(update, payload: payload)
    }

    public static func awarenessQuery() throws -> YSyncMessage {
        let payload = try readingBuffer { yrs_bridge_sync_message_awareness_query(&$0) }
        return .awarenessQuery(payload: payload)
    }

    public static func decodePayload(_ payload: Data) throws -> [YSyncMessage] {
        let data = try withUInt8Pointer(payload) { pointer, length in
            return try readingBuffer {
                yrs_bridge_sync_decode_messages(
                    pointer,
                    length,
                    &$0
                )
            }
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let entries = object as? [[String: Any]] ?? []
        return try entries.map { try message(from: $0) }
    }

    public static func joinedPayload(_ messages: [YSyncMessage]) -> Data {
        messages.reduce(into: Data()) { result, message in
            result.append(message.payload)
        }
    }

    private static func encodeMessage(
        _ data: Data,
        _ operation: (UnsafePointer<UInt8>, UInt, UnsafeMutablePointer<YrsBridgeBuffer>) -> Int32
    ) throws -> Data {
        try withUInt8Pointer(data) { pointer, length in
            return try readingBuffer {
                operation(
                    pointer,
                    length,
                    &$0
                )
            }
        }
    }

    private static func message(from entry: [String: Any]) throws -> YSyncMessage {
        let kind = entry["kind"] as? String
        switch kind {
        case "syncStep1":
            let stateVector = YStateVector(try byteData(entry["stateVector"]))
            return .syncStep1(stateVector, payload: try syncStep1(stateVector).payload)
        case "syncStep2":
            let update = YUpdate.v1(try byteData(entry["update"]))
            return .syncStep2(update, payload: try syncStep2(update).payload)
        case "update":
            let update = YUpdate.v1(try byteData(entry["update"]))
            return .update(update, payload: try YSyncMessage.update(update).payload)
        case "awareness":
            let update = YAwarenessUpdate(try byteData(entry["update"]))
            return .awareness(update, payload: try awareness(update).payload)
        case "awarenessQuery":
            return try awarenessQuery()
        case "auth":
            return .auth(reason: entry["reason"] as? String, payload: Data())
        case "custom":
            let tag = (entry["tag"] as? NSNumber)?.uint8Value ?? 0
            let data = try byteData(entry["data"])
            return .custom(tag: tag, data: data, payload: Data())
        default:
            throw YError.decodeFailure
        }
    }

    private static func byteData(_ value: Any?) throws -> Data {
        guard let values = value as? [Any] else {
            throw YError.decodeFailure
        }
        let bytes = try values.map { value -> UInt8 in
            if let byte = value as? UInt8 {
                return byte
            }
            if let byte = (value as? NSNumber)?.uint8Value {
                return byte
            }
            throw YError.decodeFailure
        }
        return Data(bytes)
    }
}

public enum YSyncProtocol {
    public static func start(awareness: YAwareness) throws -> Data {
        try readingBuffer { yrs_bridge_sync_start(awareness.handle, &$0) }
    }

    public static func handle(_ payload: Data, awareness: YAwareness) throws -> Data {
        try withUInt8Pointer(payload) { pointer, length in
            return try readingBuffer {
                yrs_bridge_sync_handle(
                    awareness.handle,
                    pointer,
                    length,
                    &$0
                )
            }
        }
    }
}
