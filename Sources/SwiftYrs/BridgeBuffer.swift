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
/// code; it should do nothing but invoke the shim call.
func readingBuffer(_ fill: (inout YrsBridgeBuffer) -> Int32) throws -> Data {
    var buffer = YrsBridgeBuffer(data: nil, len: 0)
    try throwIfNeeded(fill(&buffer))
    defer {
        yrs_bridge_buffer_destroy(buffer)
    }
    return data(from: buffer)
}

/// Runs a shim call that fills an **Owned Handle** out-parameter, then wraps the
/// non-null result with `make`.
///
/// This owns the "out-parameter → status check → null guard → construct" dance
/// once, including the null-handle → `YError.nullPointer` mapping (ADR-0008), so
/// branch-returning accessors stop re-typing it. `fill` does nothing but invoke
/// the shim call with the supplied out-parameter.
func makeBranch<T>(
    _ make: (OpaquePointer) -> T,
    _ fill: (inout OpaquePointer?) -> Int32
) throws -> T {
    var output: OpaquePointer?
    try throwIfNeeded(fill(&output))
    guard let output else {
        throw YError.nullPointer
    }
    return make(output)
}

/// Runs a shim call that fills a scalar out-parameter (e.g. a length or a
/// boolean), then returns it. Owns the zero-initialise / status-check pair so
/// scalar accessors stop re-typing it.
func readingScalar<T>(_ initial: T, _ fill: (inout T) -> Int32) throws -> T {
    var output = initial
    try throwIfNeeded(fill(&output))
    return output
}

/// Runs a shim call with bytes borrowed from Swift `Data`, concentrating the
/// input-side pointer binding ritual in one auditable place.
func withUInt8Pointer<T>(
    _ data: Data,
    _ body: (UnsafePointer<UInt8>, UInt) throws -> T
) throws -> T {
    try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            throw YError.decodeFailure
        }
        return try body(baseAddress.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
    }
}
