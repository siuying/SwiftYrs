import Foundation
import SwiftYrs

public enum HocuspocusCodecError: Error, Equatable {
    case malformedMessage
    case unsupportedMessageType(UInt64)
    case unsupportedAuthSubtype(UInt64)
}

public enum HocuspocusAuthMessage: Equatable {
    case token(String, version: String)
    case permissionDenied(reason: String)
    case authenticated(scope: String)
}

public enum HocuspocusMessage: Equatable {
    case sync(documentName: String, YSyncMessage)
    case awareness(documentName: String, YAwarenessUpdate)
    case auth(documentName: String, HocuspocusAuthMessage)
    case queryAwareness(documentName: String)
    case stateless(documentName: String, payload: String)
    case close(documentName: String, reason: String)
    case syncStatus(documentName: String, applied: Bool)

    public func encoded() -> Data {
        var encoder = HocuspocusEncoder()
        switch self {
        case let .sync(documentName, message):
            encoder.writeString(documentName)
            encoder.writeVarUint(0)
            encoder.writeData(message.payload)
        case let .awareness(documentName, update):
            encoder.writeString(documentName)
            encoder.writeVarUint(1)
            encoder.writeBytes(update.data)
        case let .auth(documentName, auth):
            encoder.writeString(documentName)
            encoder.writeVarUint(2)
            switch auth {
            case let .token(token, version):
                encoder.writeVarUint(0)
                encoder.writeString(token)
                encoder.writeString(version)
            case let .permissionDenied(reason):
                encoder.writeVarUint(1)
                encoder.writeString(reason)
            case let .authenticated(scope):
                encoder.writeVarUint(2)
                encoder.writeString(scope)
            }
        case let .queryAwareness(documentName):
            encoder.writeString(documentName)
            encoder.writeVarUint(3)
        case let .stateless(documentName, payload):
            encoder.writeString(documentName)
            encoder.writeVarUint(5)
            encoder.writeString(payload)
        case let .close(documentName, reason):
            encoder.writeString(documentName)
            encoder.writeVarUint(7)
            encoder.writeString(reason)
        case let .syncStatus(documentName, applied):
            encoder.writeString(documentName)
            encoder.writeVarUint(8)
            encoder.writeVarInt(applied ? 1 : 0)
        }
        return encoder.data
    }

    public static func decode(_ data: Data) throws -> HocuspocusMessage {
        var decoder = HocuspocusDecoder(data: data)
        let documentName = try decoder.readString()
        let messageType = try decoder.readVarUint()
        switch messageType {
        case 0:
            let payload = decoder.readRemainingData()
            let messages = try YSyncMessage.decodePayload(payload)
            guard messages.count == 1, let message = messages.first else {
                throw HocuspocusCodecError.malformedMessage
            }
            return .sync(documentName: documentName, message)
        case 1:
            let update = try YAwarenessUpdate(decoder.readBytes())
            try decoder.requireEnd()
            return .awareness(documentName: documentName, update)
        case 2:
            let subtype = try decoder.readVarUint()
            let auth: HocuspocusAuthMessage
            switch subtype {
            case 0:
                auth = try .token(decoder.readString(), version: decoder.readString())
            case 1:
                auth = try .permissionDenied(reason: decoder.readString())
            case 2:
                auth = try .authenticated(scope: decoder.readString())
            default:
                throw HocuspocusCodecError.unsupportedAuthSubtype(subtype)
            }
            try decoder.requireEnd()
            return .auth(documentName: documentName, auth)
        case 3:
            try decoder.requireEnd()
            return .queryAwareness(documentName: documentName)
        case 5:
            let payload = try decoder.readString()
            try decoder.requireEnd()
            return .stateless(documentName: documentName, payload: payload)
        case 7:
            let reason = try decoder.readString()
            try decoder.requireEnd()
            return .close(documentName: documentName, reason: reason)
        case 8:
            let applied = try decoder.readVarInt() != 0
            try decoder.requireEnd()
            return .syncStatus(documentName: documentName, applied: applied)
        default:
            throw HocuspocusCodecError.unsupportedMessageType(messageType)
        }
    }
}

struct HocuspocusEncoder {
    private(set) var data = Data()

    mutating func writeVarUint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    mutating func writeVarInt(_ value: Int64) {
        let encoded = UInt64(bitPattern: (value << 1) ^ (value >> 63))
        writeVarUint(encoded)
    }

    mutating func writeString(_ value: String) {
        let bytes = Data(value.utf8)
        writeVarUint(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func writeBytes(_ value: Data) {
        writeVarUint(UInt64(value.count))
        data.append(value)
    }

    mutating func writeData(_ value: Data) {
        data.append(value)
    }
}

struct HocuspocusDecoder {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readVarUint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                throw HocuspocusCodecError.malformedMessage
            }
        }
        throw HocuspocusCodecError.malformedMessage
    }

    mutating func readVarInt() throws -> Int64 {
        let value = try readVarUint()
        return Int64(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
    }

    mutating func readString() throws -> String {
        let length = try readVarUint()
        guard length <= UInt64(data.count - offset) else {
            throw HocuspocusCodecError.malformedMessage
        }
        let end = offset + Int(length)
        let bytes = data[offset..<end]
        offset = end
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw HocuspocusCodecError.malformedMessage
        }
        return string
    }

    mutating func readBytes() throws -> Data {
        let length = try readVarUint()
        guard length <= UInt64(data.count - offset) else {
            throw HocuspocusCodecError.malformedMessage
        }
        let end = offset + Int(length)
        defer {
            offset = end
        }
        return Data(data[offset..<end])
    }

    mutating func readRemainingData() -> Data {
        defer {
            offset = data.count
        }
        return Data(data[offset..<data.count])
    }

    func requireEnd() throws {
        if offset != data.count {
            throw HocuspocusCodecError.malformedMessage
        }
    }
}
