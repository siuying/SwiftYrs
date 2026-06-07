import Foundation
import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

/// Awareness (presence) propagation over the WebRTC transport, interoperable
/// with the real `y-webrtc` peer: presence flows both directions, and a peer's
/// collaborators disappear when its data channel closes.
@Suite(.serialized)
struct WebRTCAwarenessInteropTests {
    @Test
    func awarenessPropagatesAndCleansUpWithRealYWebRTCPeer() async throws {
        let server = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
        defer { server.stop() }
        let ready = try await server.waitForLine("signaling server ready") { $0["type"] as? String == "ready" }
        let port = try #require(ready["port"] as? Int)
        let signaling = "ws://127.0.0.1:\(port)"
        let room = "awareness-room"

        let doc = YDoc(clientID: 1)
        let provider = WebRTCProvider(
            room, doc: doc, signaling: [try #require(URL(string: signaling))],
            options: WebRTCProvider.Options(iceServers: [])
        )
        try await provider.connect()
        defer { Task { await provider.destroy() } }

        let peer = try JSONLineProcess.node(script: "webrtc-peer.ts", arguments: [signaling, room])
        var peerStopped = false
        defer { if !peerStopped { peer.stop() } }
        _ = try await peer.waitForLine("y-webrtc peer ready", timeout: .seconds(15)) {
            $0["type"] as? String == "ready"
        }
        try await e2eEventually("Swift provider connected to y-webrtc peer", timeout: .seconds(15)) {
            await !provider.connectedPeers.isEmpty
        }

        // The y-webrtc peer's presence appears on the Swift side.
        try await peer.send(["type": "setAwareness", "state": ["name": "js-peer"]])
        try await e2eEventually("y-webrtc awareness appears on Swift", timeout: .seconds(15)) {
            try await swiftHasPresence(provider, name: "js-peer")
        }

        // Swift's presence appears on the y-webrtc peer.
        try await provider.awareness.setLocalState(["name": "swift-peer"])
        try await e2eEventually("Swift awareness appears on y-webrtc", timeout: .seconds(15)) {
            let response = try await peer.request(["type": "getAwareness"], responseType: "awareness")
            let states = response["states"] as? [[String: Any]] ?? []
            return states.contains { ($0["state"] as? [String: Any])?["name"] as? String == "swift-peer" }
        }

        // When the y-webrtc peer disconnects, only its presence is removed.
        peer.stop()
        peerStopped = true
        try await e2eEventually("y-webrtc awareness removed after disconnect", timeout: .seconds(15)) {
            try await !swiftHasPresence(provider, name: "js-peer")
        }
    }

    private func swiftHasPresence(_ provider: WebRTCProvider, name: String) async throws -> Bool {
        let awareness = await provider.awareness
        return try awareness.states().contains { entry in
            (entry.state as? [String: Any])?["name"] as? String == name
        }
    }
}
