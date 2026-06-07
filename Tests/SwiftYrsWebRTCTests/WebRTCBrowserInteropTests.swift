import Foundation
import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

/// Proves wire-level interop with the real browser `y-webrtc` library: a Swift
/// `WebRTCProvider` and a genuine `y-webrtc` peer (running `@roamhq/wrtc` under
/// node) join the same room on the same signaling server and converge a
/// document over a direct data channel. This validates the simple-peer seam
/// (ADR-0020) against the actual implementation, not another Swift peer.
@Suite(.serialized)
struct WebRTCBrowserInteropTests {
    @Test
    func swiftProviderSyncsWithRealYWebRTCPeer() async throws {
        let server = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
        defer { server.stop() }
        let ready = try await server.waitForLine("signaling server ready") { $0["type"] as? String == "ready" }
        let port = try #require(ready["port"] as? Int)
        let signaling = "ws://127.0.0.1:\(port)"
        let room = "interop-room"

        // Swift side.
        let doc = YDoc(clientID: 1)
        let text = try doc.text(named: "body")
        let provider = WebRTCProvider(
            room, doc: doc, signaling: [try #require(URL(string: signaling))],
            options: WebRTCProvider.Options(iceServers: [])
        )
        try await provider.connect()
        defer { Task { await provider.destroy() } }

        // Real y-webrtc peer under node.
        let peer = try JSONLineProcess.node(script: "webrtc-peer.ts", arguments: [signaling, room])
        defer { peer.stop() }
        _ = try await peer.waitForLine("y-webrtc peer ready", timeout: .seconds(15)) {
            $0["type"] as? String == "ready"
        }

        // They establish a direct data-channel connection through signaling.
        try await e2eEventually("Swift provider connected to y-webrtc peer", timeout: .seconds(15)) {
            await !provider.connectedPeers.isEmpty
        }

        // Text inserted on the real y-webrtc peer converges on the Swift document.
        try await peer.send(["type": "insertText", "text": "hello"])
        try await e2eEventually("y-webrtc text converges on Swift document", timeout: .seconds(15)) {
            try doc.read { try $0.string(from: text) == "hello" }
        }

        // And a Swift edit converges back onto the y-webrtc peer.
        try doc.write { try $0.insert(" world", into: text, at: 5) }
        try await e2eEventually("Swift text converges on y-webrtc peer", timeout: .seconds(15)) {
            let response = try await peer.request(["type": "getText"], responseType: "text")
            return response["text"] as? String == "hello world"
        }
    }

    @Test
    func swiftProviderSyncsWithPasswordProtectedYWebRTCPeer() async throws {
        let server = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
        defer { server.stop() }
        let ready = try await server.waitForLine("signaling server ready") { $0["type"] as? String == "ready" }
        let port = try #require(ready["port"] as? Int)
        let signaling = "ws://127.0.0.1:\(port)"
        let room = "password-interop-room"
        let password = "correct horse battery staple"

        let doc = YDoc(clientID: 101)
        let text = try doc.text(named: "body")
        let provider = WebRTCProvider(
            room, doc: doc, signaling: [try #require(URL(string: signaling))],
            options: WebRTCProvider.Options(password: password, iceServers: [])
        )
        try await provider.connect()
        defer { Task { await provider.destroy() } }

        let peer = try JSONLineProcess.node(script: "webrtc-peer.ts", arguments: [signaling, room, password])
        defer { peer.stop() }
        _ = try await peer.waitForLine("password y-webrtc peer ready", timeout: .seconds(15)) {
            $0["type"] as? String == "ready"
        }

        try await e2eEventually("Swift provider connected to passworded y-webrtc peer", timeout: .seconds(15)) {
            await !provider.connectedPeers.isEmpty
        }

        try await peer.send(["type": "insertText", "text": "encrypted hello"])
        try await e2eEventually("passworded y-webrtc text converges on Swift document", timeout: .seconds(15)) {
            try doc.read { try $0.string(from: text) == "encrypted hello" }
        }

        try doc.write { try $0.insert(" world", into: text, at: 15) }
        try await e2eEventually("Swift text converges on passworded y-webrtc peer", timeout: .seconds(15)) {
            let response = try await peer.request(["type": "getText"], responseType: "text")
            return response["text"] as? String == "encrypted hello world"
        }
    }
}
