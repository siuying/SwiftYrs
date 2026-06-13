import Foundation
import YrsBridgeFFI

/// Encodes and decodes values using lib0's variant codec (`writeAny`/`readAny`),
/// the same binary format yrs uses on the wire and y-webrtc uses for encrypted
/// signaling payloads. Values cross the boundary as plain JSON-shaped Foundation
/// objects (`String`, `NSNumber`, `Bool`, `NSNull`, `Array`, `Dictionary`).
public enum Lib0Any {
    /// Encodes a plain JSON-shaped value to its lib0 `writeAny` byte representation.
    public static func encode(_ value: Any) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try json.withUnsafeBytes { bytes -> Data in
            guard let baseAddress = bytes.baseAddress else {
                throw YError.decodeFailure
            }
            return try readingBuffer {
                yrs_bridge_lib0_encode_any(
                    baseAddress.assumingMemoryBound(to: UInt8.self),
                    UInt(bytes.count),
                    &$0
                )
            }
        }
    }

    /// Decodes lib0 `readAny` bytes back into a plain JSON-shaped value.
    public static func decode(_ bytes: Data) throws -> Any {
        let data = try bytes.withUnsafeBytes { raw -> Data in
            guard let baseAddress = raw.baseAddress else {
                throw YError.decodeFailure
            }
            return try readingBuffer {
                yrs_bridge_lib0_decode_any(
                    baseAddress.assumingMemoryBound(to: UInt8.self),
                    UInt(raw.count),
                    &$0
                )
            }
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
