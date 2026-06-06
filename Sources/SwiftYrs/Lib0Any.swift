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
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try json.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw YError.decodeFailure
            }
            try throwIfNeeded(yrs_bridge_lib0_encode_any(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(bytes.count),
                &buffer
            ))
        }
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        return SwiftYrs.data(from: buffer)
    }

    /// Decodes lib0 `readAny` bytes back into a plain JSON-shaped value.
    public static func decode(_ bytes: Data) throws -> Any {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try bytes.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else {
                throw YError.decodeFailure
            }
            try throwIfNeeded(yrs_bridge_lib0_decode_any(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(raw.count),
                &buffer
            ))
        }
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        return try JSONSerialization.jsonObject(
            with: SwiftYrs.data(from: buffer),
            options: [.fragmentsAllowed]
        )
    }
}
