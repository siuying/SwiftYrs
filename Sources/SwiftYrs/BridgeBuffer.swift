import Foundation
import YrsBridgeFFI

/// Runs a shim call that fills a `YrsBridgeBuffer`, then hands back its bytes.
///
/// This is the one place that owns the **Shim Buffer** lifecycle (ADR-0015):
/// allocate the out-parameter, translate the FFI status code into a `YError`,
/// release the buffer with the matching `yrs_bridge_buffer_destroy`, and extract
/// the bytes. Every accessor that reads bytes back from the native layer routes
/// through here instead of re-typing that four-step dance.
///
/// `fill` receives the zeroed buffer by reference and returns the FFI status
/// code; it should do nothing but invoke the shim call. Input-pointer guards
/// (e.g. `withUnsafeBytes`/`withCString`) belong outside, wrapping this call.
func readingBuffer(_ fill: (inout YrsBridgeBuffer) -> Int32) throws -> Data {
    var buffer = YrsBridgeBuffer(data: nil, len: 0)
    try throwIfNeeded(fill(&buffer))
    defer {
        yrs_bridge_buffer_destroy(buffer)
    }
    return data(from: buffer)
}
