import Foundation
@testable import SwiftYrs
import Testing
import YrsBridgeFFI

@Test
func withUInt8PointerProvidesBoundBytesAndLength() throws {
    let data = Data([1, 2, 3])

    let copied = try withUInt8Pointer(data) { pointer, length in
        (0..<Int(length)).map { pointer[$0] }
    }

    #expect(copied == [1, 2, 3])
}

@Test
func registerObservationThrowsWhenShimReturnsNilHandle() throws {
    let handle = try #require(OpaquePointer(bitPattern: 1))

    #expect(throws: YError.nullPointer) {
        try registerObservation(handle: handle, observe: { _, _, _ in nil }) { _ in }
    }
}
