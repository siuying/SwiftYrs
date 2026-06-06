import Foundation
import Testing
import SwiftYrs

@Test
func lib0AnyRoundTripsAString() throws {
    let bytes = try Lib0Any.encode("hello")
    let value = try Lib0Any.decode(bytes)
    #expect(value as? String == "hello")
}

@Test
func lib0AnyRoundTripsAnInteger() throws {
    let value = try Lib0Any.decode(try Lib0Any.encode(42))
    #expect(value as? Int == 42)
}

@Test
func lib0AnyRoundTripsAFloat() throws {
    let value = try Lib0Any.decode(try Lib0Any.encode(3.5))
    #expect(value as? Double == 3.5)
}

@Test
func lib0AnyRoundTripsABool() throws {
    let value = try Lib0Any.decode(try Lib0Any.encode(true))
    #expect(value as? Bool == true)
}

@Test
func lib0AnyRoundTripsNull() throws {
    let value = try Lib0Any.decode(try Lib0Any.encode(NSNull()))
    #expect(value is NSNull)
}

@Test
func lib0AnyRoundTripsAnArray() throws {
    let value = try Lib0Any.decode(try Lib0Any.encode([1, 2, 3]))
    #expect(value as? [Int] == [1, 2, 3])
}

@Test
func lib0AnyRoundTripsANestedSignalObject() throws {
    // The shape y-webrtc serializes for an encrypted offer signal.
    let signal: [String: Any] = [
        "type": "offer",
        "sdp": "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n",
        "candidate": [
            "candidate": "candidate:1 1 udp 2122260223 192.168.1.2 54321 typ host",
            "sdpMid": "0",
            "sdpMLineIndex": 0,
        ],
    ]
    let decoded = try Lib0Any.decode(try Lib0Any.encode(signal))
    let object = try #require(decoded as? [String: Any])
    #expect(object["type"] as? String == "offer")
    #expect(object["sdp"] as? String == "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n")
    let candidate = try #require(object["candidate"] as? [String: Any])
    #expect(candidate["sdpMid"] as? String == "0")
    #expect(candidate["sdpMLineIndex"] as? Int == 0)
}
