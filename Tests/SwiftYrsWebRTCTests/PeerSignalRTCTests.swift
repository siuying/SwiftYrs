import Foundation
import Testing
import StreamWebRTC
@testable import SwiftYrsWebRTC

@Test
func peerSignalFromOfferSessionDescription() throws {
    let sdp = RTCSessionDescription(type: .offer, sdp: "v=0\r\n")
    #expect(PeerSignal(sessionDescription: sdp) == .offer(sdp: "v=0\r\n"))
}

@Test
func peerSignalFromAnswerSessionDescription() throws {
    let sdp = RTCSessionDescription(type: .answer, sdp: "v=0\r\na\r\n")
    #expect(PeerSignal(sessionDescription: sdp) == .answer(sdp: "v=0\r\na\r\n"))
}

@Test
func offerPeerSignalConvertsToSessionDescription() throws {
    let sdp = try #require(PeerSignal.offer(sdp: "v=0\r\n").sessionDescription)
    #expect(sdp.type == .offer)
    #expect(sdp.sdp == "v=0\r\n")
}

@Test
func candidatePeerSignalRoundTripsThroughRTCIceCandidate() throws {
    let original = RTCIceCandidate(
        sdp: "candidate:1 1 udp 2122260223 192.168.1.2 54321 typ host",
        sdpMLineIndex: 0,
        sdpMid: "0"
    )
    let signal = PeerSignal(iceCandidate: original)
    #expect(signal == .candidate(PeerSignal.IceCandidate(
        candidate: "candidate:1 1 udp 2122260223 192.168.1.2 54321 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0
    )))

    let rebuilt = try #require(signal.iceCandidate)
    #expect(rebuilt.sdp == original.sdp)
    #expect(rebuilt.sdpMid == "0")
    #expect(rebuilt.sdpMLineIndex == 0)
}

@Test
func nonCandidateSignalsHaveNoIceCandidate() {
    #expect(PeerSignal.offer(sdp: "x").iceCandidate == nil)
    #expect(PeerSignal.candidate(.init(candidate: "c", sdpMid: nil, sdpMLineIndex: nil)).sessionDescription == nil)
}
