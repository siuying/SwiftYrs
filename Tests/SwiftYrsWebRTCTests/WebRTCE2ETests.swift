import Foundation
import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

@Suite(.serialized)
struct WebRTCE2ETests {
    @Test
    func twoSwiftProvidersSyncADocumentOverADataChannel() async throws {
        let server = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
        defer { server.stop() }
        let ready = try await server.waitForLine("signaling server ready") { $0["type"] as? String == "ready" }
        let port = try #require(ready["port"] as? Int)
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))

        let docA = YDoc(clientID: 1)
        let textA = try docA.text(named: "body")
        let providerA = WebRTCProvider("room-e2e", doc: docA, signaling: [url], options: loopbackOptions())

        let docB = YDoc(clientID: 2)
        let textB = try docB.text(named: "body")
        let providerB = WebRTCProvider("room-e2e", doc: docB, signaling: [url], options: loopbackOptions())

        // Observe peer A's synced stream to prove it latches true (not vacuously).
        let syncedBox = E2EBox<Bool>()
        let syncedTask = Task { [stream = providerA.synced] in
            for await value in stream { await syncedBox.set(value) }
        }
        defer { syncedTask.cancel() }

        try await providerA.connect()
        try await e2eEventually("provider A connected to signaling", timeout: .seconds(5)) {
            await providerA.connected
        }
        try await providerB.connect()
        try await e2eEventually("provider B connected to signaling", timeout: .seconds(5)) {
            await providerB.connected
        }
        defer {
            Task { await providerA.destroy() }
            Task { await providerB.destroy() }
        }

        // The mesh establishes a direct data-channel connection over loopback.
        try await e2eEventually("peers connected", timeout: .seconds(5)) {
            let a = await providerA.connectedPeers
            let b = await providerB.connectedPeers
            return !a.isEmpty && !b.isEmpty
        }

        // An edit on A converges on B.
        try docA.write { try $0.insert("hello", into: textA, at: 0) }
        try await e2eEventually("edit on A converges on B", timeout: .seconds(5)) {
            try docB.read { try $0.string(from: textB) == "hello" }
        }

        // And an edit on B converges on A (bidirectional).
        try docB.write { try $0.insert(" world", into: textB, at: 5) }
        try await e2eEventually("edit on B converges on A", timeout: .seconds(5)) {
            try docA.read { try $0.string(from: textA) == "hello world" }
        }

        // `synced` latched true once a peer completed initial sync.
        try await e2eEventually("synced latched true", timeout: .seconds(5)) {
            await syncedBox.value == true
        }

        await providerA.destroy()
        await providerB.destroy()
    }

    @Test
    func destroyBroadcastsOwnedAwarenessRemoval() async throws {
        let server = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
        defer { server.stop() }
        let ready = try await server.waitForLine("signaling server ready") { $0["type"] as? String == "ready" }
        let port = try #require(ready["port"] as? Int)
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))

        let providerA = WebRTCProvider(
            "room-awareness-removal", doc: YDoc(clientID: 11), signaling: [url], options: loopbackOptions()
        )
        let providerB = WebRTCProvider(
            "room-awareness-removal", doc: YDoc(clientID: 22), signaling: [url], options: loopbackOptions()
        )
        defer {
            Task { await providerA.destroy() }
            Task { await providerB.destroy() }
        }

        let awarenessA = await providerA.awareness
        let awarenessB = await providerB.awareness
        let clientID = awarenessA.clientID
        try awarenessA.setLocalState(["name": "swift"])

        try await providerA.connect()
        try await e2eEventually("provider A connected to signaling", timeout: .seconds(5)) {
            await providerA.connected
        }
        try await providerB.connect()
        try await e2eEventually("provider B connected to signaling", timeout: .seconds(5)) {
            await providerB.connected
        }
        try await e2eEventually("peers connected", timeout: .seconds(5)) {
            let a = await providerA.connectedPeers
            let b = await providerB.connectedPeers
            return !a.isEmpty && !b.isEmpty
        }

        try await e2eEventually("awareness state received by B", timeout: .seconds(5)) {
            try awarenessB.state(for: clientID) != nil
        }

        await providerA.destroy()

        try await e2eEventually("awareness state removed after A destroys", timeout: .seconds(5)) {
            try awarenessB.state(for: clientID) == nil
        }
        await providerB.destroy()
    }

    private func loopbackOptions() -> WebRTCProvider.Options {
        // No STUN: host candidates over loopback are enough for two local peers.
        WebRTCProvider.Options(iceServers: [])
    }
}
