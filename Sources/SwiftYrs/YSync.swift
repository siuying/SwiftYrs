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
        try decodePayload(payload, includePayload: true)
    }

    static func decodePayload(_ payload: Data, includePayload: Bool) throws -> [YSyncMessage] {
        let data = try withUInt8Pointer(payload) { pointer, length in
            return try readingBuffer {
                yrs_bridge_sync_decode_messages(
                    pointer,
                    length,
                    &$0
                )
            }
        }
        let entries = try JSONDecoder().decode([DecodedMessage].self, from: data)
        return try entries.map { try message(from: $0, includePayload: includePayload) }
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

    private struct DecodedMessage: Decodable {
        let kind: String
        let stateVector: [UInt8]?
        let update: [UInt8]?
        let reason: String?
        let tag: UInt8?
        let data: [UInt8]?
    }

    private static func message(from entry: DecodedMessage, includePayload: Bool) throws -> YSyncMessage {
        switch entry.kind {
        case "syncStep1":
            let stateVector = YStateVector(try byteData(entry.stateVector))
            return .syncStep1(stateVector, payload: includePayload ? try syncStep1(stateVector).payload : Data())
        case "syncStep2":
            let update = YUpdate.v1(try byteData(entry.update))
            return .syncStep2(update, payload: includePayload ? try syncStep2(update).payload : Data())
        case "update":
            let update = YUpdate.v1(try byteData(entry.update))
            return .update(update, payload: includePayload ? try YSyncMessage.update(update).payload : Data())
        case "awareness":
            let update = YAwarenessUpdate(try byteData(entry.update))
            return .awareness(update, payload: includePayload ? try awareness(update).payload : Data())
        case "awarenessQuery":
            return includePayload ? try awarenessQuery() : .awarenessQuery(payload: Data())
        case "auth":
            return .auth(reason: entry.reason, payload: Data())
        case "custom":
            let data = try byteData(entry.data)
            return .custom(tag: entry.tag ?? 0, data: data, payload: Data())
        default:
            throw YError.decodeFailure
        }
    }

    private static func byteData(_ value: [UInt8]?) throws -> Data {
        guard let value else {
            throw YError.decodeFailure
        }
        return Data(value)
    }
}

public enum YSyncProtocol {
    private static let transactionRetryDelay: Duration = .milliseconds(5)
    private static let transactionRetryTimeout: Duration = .seconds(1)

    /// Waits up to one second for document contention, then throws `YError.transactionConflict`.
    public static func start(awareness: YAwareness) throws -> Data {
        let stateVector = try retryDocumentOperation { try awareness.document.stateVector() }
        let step1 = try YSyncMessage.syncStep1(stateVector)
        let presence = try YSyncMessage.awareness(awareness.encodeUpdate())
        return YSyncMessage.joinedPayload([step1, presence])
    }

    /// Waits up to one second per document operation, then throws `YError.transactionConflict`.
    public static func handle(_ payload: Data, awareness: YAwareness) throws -> Data {
        try handle(payload, awareness: awareness, origin: nil)
    }

    /// Tags inbound awareness events with `origin` so providers can suppress echoes.
    /// Waits up to one second per document operation, then throws `YError.transactionConflict`.
    public static func handle(_ payload: Data, awareness: YAwareness, origin: String?) throws -> Data {
        let messages = try YSyncMessage.decodePayload(payload, includePayload: false)
        var responses: [YSyncMessage] = []
        for message in messages {
            switch message {
            case let .syncStep1(stateVector, _):
                let update = try retryDocumentOperation {
                    try awareness.document.encodeStateAsUpdateV1(from: stateVector)
                }
                responses.append(try .syncStep2(update))
            case let .syncStep2(update, _), let .update(update, _):
                try retryDocumentOperation { try awareness.document.apply(update) }
            case let .awareness(update, _):
                try awareness.applyUpdate(update, origin: origin)
            case .awarenessQuery:
                responses.append(try .awareness(awareness.encodeUpdate()))
            case let .auth(reason, _):
                if reason != nil { throw YError.decodeFailure }
            case .custom:
                throw YError.decodeFailure
            }
        }
        return YSyncMessage.joinedPayload(responses)
    }

    private static func retryDocumentOperation<T>(_ operation: () throws -> T) throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: transactionRetryTimeout)
        while true {
            do {
                return try operation()
            } catch YError.transactionConflict {
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { throw YError.transactionConflict }
                let delay = min(transactionRetryDelay, remaining).components
                Thread.sleep(forTimeInterval: Double(delay.seconds) + Double(delay.attoseconds) / 1e18)
                guard clock.now < deadline else { throw YError.transactionConflict }
            }
        }
    }
}
