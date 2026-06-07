import Foundation
import Testing
@testable import SwiftYrsWebRTC

@Test
func peerSignalDecodesAnOffer() throws {
    let json = Data(#"{"type":"offer","sdp":"v=0\r\n"}"#.utf8)
    let signal = try PeerSignal.decode(from: json)
    #expect(signal == .offer(sdp: "v=0\r\n"))
}

@Test
func peerSignalDecodesAnAnswer() throws {
    let json = Data(#"{"type":"answer","sdp":"v=0\r\na=x\r\n"}"#.utf8)
    #expect(try PeerSignal.decode(from: json) == .answer(sdp: "v=0\r\na=x\r\n"))
}

@Test
func peerSignalDecodesACandidate() throws {
    let json = Data(#"""
    {"type":"candidate","candidate":{"candidate":"candidate:1 1 udp 2122260223 192.168.1.2 54321 typ host","sdpMid":"0","sdpMLineIndex":0}}
    """#.utf8)
    let signal = try PeerSignal.decode(from: json)
    #expect(signal == .candidate(PeerSignal.IceCandidate(
        candidate: "candidate:1 1 udp 2122260223 192.168.1.2 54321 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )))
}

@Test
func peerSignalDecodesIgnoredSignals() throws {
    #expect(try PeerSignal.decode(from: Data(#"{"type":"renegotiate"}"#.utf8)) == .renegotiate)
    #expect(try PeerSignal.decode(from: Data(#"{"type":"transceiverRequest"}"#.utf8)) == .transceiverRequest)
}

@Test
func peerSignalEncodesAnOfferAsSimplePeerShape() throws {
    let object = try #require(PeerSignal.offer(sdp: "v=0\r\n").jsonObject() as? [String: Any])
    #expect(object["type"] as? String == "offer")
    #expect(object["sdp"] as? String == "v=0\r\n")
}

@Test
func peerSignalEncodesACandidateWithNestedShape() throws {
    let signal = PeerSignal.candidate(PeerSignal.IceCandidate(
        candidate: "candidate:1 1 udp 1 10.0.0.1 5 typ host", sdpMid: "0", sdpMLineIndex: 0
    ))
    let object = try #require(signal.jsonObject() as? [String: Any])
    #expect(object["type"] as? String == "candidate")
    let candidate = try #require(object["candidate"] as? [String: Any])
    #expect(candidate["candidate"] as? String == "candidate:1 1 udp 1 10.0.0.1 5 typ host")
    #expect(candidate["sdpMid"] as? String == "0")
    #expect(candidate["sdpMLineIndex"] as? Int == 0)
}

@Test
func peerSignalRoundTripsThroughJSON() throws {
    let signals: [PeerSignal] = [
        .offer(sdp: "o\r\n"),
        .answer(sdp: "a\r\n"),
        .candidate(PeerSignal.IceCandidate(candidate: "c", sdpMid: "1", sdpMLineIndex: 2)),
        .candidate(PeerSignal.IceCandidate(candidate: "c", sdpMid: nil, sdpMLineIndex: nil)),
    ]
    for signal in signals {
        let data = try JSONSerialization.data(withJSONObject: signal.jsonObject())
        #expect(try PeerSignal.decode(from: data) == signal, "round-trip failed for \(signal)")
    }
}

@Test
func peerSignalRejectsMalformedSignal() {
    #expect(throws: WebRTCSignalingError.malformedSignal) {
        try PeerSignal.decode(from: Data(#"{"sdp":"v=0"}"#.utf8))
    }
}
