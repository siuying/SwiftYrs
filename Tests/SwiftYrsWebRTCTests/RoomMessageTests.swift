import Foundation
import Testing
@testable import SwiftYrsWebRTC

@Test
func roomMessageEncodesAnAnnounce() throws {
    let object = try #require(RoomMessage.announce(from: "peer-a").jsonObject() as? [String: Any])
    #expect(object["type"] as? String == "announce")
    #expect(object["from"] as? String == "peer-a")
}

@Test
func roomMessageEncodesASignal() throws {
    let message = RoomMessage.signal(
        from: "peer-a", to: "peer-b", token: 123.5, signal: .offer(sdp: "v=0\r\n")
    )
    let object = try #require(message.jsonObject() as? [String: Any])
    #expect(object["type"] as? String == "signal")
    #expect(object["from"] as? String == "peer-a")
    #expect(object["to"] as? String == "peer-b")
    #expect(object["token"] as? Double == 123.5)
    let signal = try #require(object["signal"] as? [String: Any])
    #expect(signal["type"] as? String == "offer")
}

@Test
func roomMessageDecodesAnAnnounce() throws {
    let object = try JSONSerialization.jsonObject(with: Data(#"{"type":"announce","from":"peer-a"}"#.utf8))
    #expect(try RoomMessage(jsonObject: object) == .announce(from: "peer-a"))
}

@Test
func roomMessageDecodesASignalWithNestedPeerSignal() throws {
    let json = Data(#"""
    {"type":"signal","from":"peer-a","to":"peer-b","token":123.5,"signal":{"type":"answer","sdp":"a\r\n"}}
    """#.utf8)
    let object = try JSONSerialization.jsonObject(with: json)
    #expect(try RoomMessage(jsonObject: object) == .signal(
        from: "peer-a", to: "peer-b", token: 123.5, signal: .answer(sdp: "a\r\n")
    ))
}

@Test
func roomMessageRejectsUnknownType() {
    let object = ["type": "nope"]
    #expect(throws: WebRTCSignalingError.malformedSignal) {
        try RoomMessage(jsonObject: object)
    }
}
