import CommonCrypto
import CryptoKit
import Foundation
import SwiftYrs

enum SignalingCipherError: Error {
    case invalidFrame
    case unsupportedAlgorithm
    case keyDerivationFailed
}

/// y-webrtc password mode encrypts signaling payloads only. The inner room
/// message uses lib0 `writeAny`; the encrypted bytes are framed as
/// `AES-GCM`, IV, ciphertext+tag, then base64-encoded in the signaling frame.
struct SignalingCipher: @unchecked Sendable {
    private let key: SymmetricKey

    init(password: String, roomName: String) throws {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = [UInt8](password.utf8)
        let saltBytes = [UInt8](roomName.utf8)
        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            saltBytes.withUnsafeBufferPointer { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress.map { UnsafePointer<Int8>(OpaquePointer($0)) },
                    passwordBuffer.count,
                    saltBuffer.baseAddress,
                    saltBuffer.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    100_000,
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else {
            throw SignalingCipherError.keyDerivationFailed
        }
        key = SymmetricKey(data: derived)
    }

    func encryptJSON(_ value: Any) throws -> String {
        let plaintext = try Lib0Any.encode(value)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        var cipherAndTag = Data(sealed.ciphertext)
        cipherAndTag.append(sealed.tag)

        var encoder = Lib0FrameEncoder()
        encoder.writeVarString("AES-GCM")
        encoder.writeVarUint8Array(Data(nonce))
        encoder.writeVarUint8Array(cipherAndTag)
        return encoder.data.base64EncodedString()
    }

    func decryptJSON(_ base64: String) throws -> Any {
        guard let frame = Data(base64Encoded: base64) else {
            throw SignalingCipherError.invalidFrame
        }
        var decoder = Lib0FrameDecoder(frame)
        guard try decoder.readVarString() == "AES-GCM" else {
            throw SignalingCipherError.unsupportedAlgorithm
        }
        let iv = try decoder.readVarUint8Array()
        let cipherAndTag = try decoder.readVarUint8Array()
        guard cipherAndTag.count >= 16 else {
            throw SignalingCipherError.invalidFrame
        }
        let ciphertext = cipherAndTag.prefix(cipherAndTag.count - 16)
        let tag = cipherAndTag.suffix(16)
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: ciphertext,
            tag: tag
        )
        return try Lib0Any.decode(Data(AES.GCM.open(sealed, using: key)))
    }
}

private struct Lib0FrameEncoder {
    private(set) var data = Data()

    mutating func writeVarString(_ value: String) {
        writeVarUint8Array(Data(value.utf8))
    }

    mutating func writeVarUint8Array(_ value: Data) {
        writeVarUint(UInt64(value.count))
        data.append(value)
    }

    private mutating func writeVarUint(_ value: UInt64) {
        var value = value
        while value > 0x7f {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }
}

private struct Lib0FrameDecoder {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func readVarString() throws -> String {
        let bytes = try readVarUint8Array()
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw SignalingCipherError.invalidFrame
        }
        return value
    }

    mutating func readVarUint8Array() throws -> Data {
        let length = try readVarUint()
        guard length <= UInt64(Int.max), offset + Int(length) <= data.count else {
            throw SignalingCipherError.invalidFrame
        }
        let end = offset + Int(length)
        defer { offset = end }
        return data[offset..<end]
    }

    private mutating func readVarUint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 {
                return result
            }
            shift += 7
            if shift > 63 {
                throw SignalingCipherError.invalidFrame
            }
        }
        throw SignalingCipherError.invalidFrame
    }
}
