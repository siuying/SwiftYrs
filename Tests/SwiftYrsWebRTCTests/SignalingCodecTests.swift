import Foundation
import Testing
@testable import SwiftYrsWebRTC

private func decodeJSON(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test
func signalingEncodesSubscribe() throws {
    let object = try decodeJSON(SignalingCodec.subscribe(topics: ["room-1"]))
    #expect(object["type"] as? String == "subscribe")
    #expect(object["topics"] as? [String] == ["room-1"])
}

@Test
func signalingEncodesUnsubscribe() throws {
    let object = try decodeJSON(SignalingCodec.unsubscribe(topics: ["room-1"]))
    #expect(object["type"] as? String == "unsubscribe")
    #expect(object["topics"] as? [String] == ["room-1"])
}

@Test
func signalingEncodesPublishWrappingRoomMessage() throws {
    let data = try SignalingCodec.publish(topic: "room-1", data: RoomMessage.announce(from: "peer-a").jsonObject())
    let object = try decodeJSON(data)
    #expect(object["type"] as? String == "publish")
    #expect(object["topic"] as? String == "room-1")
    let inner = try #require(object["data"] as? [String: Any])
    #expect(inner["type"] as? String == "announce")
    #expect(inner["from"] as? String == "peer-a")
}

@Test
func signalingEncryptsAndDecryptsPasswordProtectedPublishPayloads() throws {
    let cipher = try SignalingCipher(password: "secret", roomName: "room-1")
    let data = try SignalingCodec.publish(
        topic: "room-1",
        data: RoomMessage.announce(from: "peer-a").jsonObject(),
        cipher: cipher
    )
    let object = try decodeJSON(data)
    #expect(object["type"] as? String == "publish")
    #expect(object["topic"] as? String == "room-1")
    #expect(object["data"] is String)

    guard case let .publish(topic, payload) = try SignalingCodec.decode(data, cipher: cipher) else {
        Issue.record("expected publish")
        return
    }
    #expect(topic == "room-1")
    let inner = try JSONSerialization.jsonObject(with: payload)
    #expect(try RoomMessage(jsonObject: inner) == .announce(from: "peer-a"))
}

@Test
func signalingRejectsPasswordProtectedPayloadWithWrongPassword() throws {
    let writer = try SignalingCipher(password: "secret", roomName: "room-1")
    let reader = try SignalingCipher(password: "wrong", roomName: "room-1")
    let data = try SignalingCodec.publish(
        topic: "room-1",
        data: RoomMessage.announce(from: "peer-a").jsonObject(),
        cipher: writer
    )
    #expect(throws: Error.self) {
        _ = try SignalingCodec.decode(data, cipher: reader)
    }
}

@Test
func signalingEncodesPing() throws {
    #expect(try decodeJSON(SignalingCodec.ping())["type"] as? String == "ping")
}

@Test
func signalingDecodesPublishExposingTopicAndData() throws {
    let frame = Data(#"""
    {"type":"publish","topic":"room-1","data":{"type":"announce","from":"peer-b"}}
    """#.utf8)
    guard case let .publish(topic, data) = try SignalingCodec.decode(frame) else {
        Issue.record("expected publish")
        return
    }
    #expect(topic == "room-1")
    let object = try JSONSerialization.jsonObject(with: data)
    #expect(try RoomMessage(jsonObject: object) == .announce(from: "peer-b"))
}

@Test
func signalingDecodesPong() throws {
    #expect(try SignalingCodec.decode(Data(#"{"type":"pong"}"#.utf8)) == .pong)
}

@Test
func signalingDecodesUnknownFramesAsIgnorable() throws {
    #expect(try SignalingCodec.decode(Data(#"{"type":"whatever"}"#.utf8)) == .ignored)
}
