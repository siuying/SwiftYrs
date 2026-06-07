import Foundation
import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

extension RealNetworkE2E {
    /// Mesh gossip across a *line* topology with a mix of Swift and JS peers,
    /// proving updates and awareness reach peers that are not directly connected
    /// to the origin. Two signaling servers force the topology: A discovers peers
    /// only on server 1, the JS peer C only on server 2, and the Swift relay B on
    /// both. A and C therefore never open a direct data channel — A only ever
    /// learns about C's edits because B re-broadcasts (gossips) them. See issue #26.
    @Suite(.serialized)
    struct WebRTCMeshInteropTests {
        @Test
        func gossipRelaysEditAndAwarenessToAnIndirectSwiftPeer() async throws {
            let serverOne = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
            let serverTwo = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
            defer {
                serverOne.stop()
                serverTwo.stop()
            }
            let readyOne = try await serverOne.waitForLine("signaling server one ready") { $0["type"] as? String == "ready" }
            let readyTwo = try await serverTwo.waitForLine("signaling server two ready") { $0["type"] as? String == "ready" }
            let portOne = try #require(readyOne["port"] as? Int)
            let portTwo = try #require(readyTwo["port"] as? Int)
            let urlOne = try #require(URL(string: "ws://127.0.0.1:\(portOne)"))
            let signalingTwo = "ws://127.0.0.1:\(portTwo)"
            let urlTwo = try #require(URL(string: signalingTwo))
            let room = "mesh-relay-room"

            // A sees only server 1; the relay B sees both servers.
            let docA = YDoc(clientID: 71)
            let textA = try docA.text(named: "body")
            let providerA = WebRTCProvider(room, doc: docA, signaling: [urlOne], options: loopbackOptions())

            let docB = YDoc(clientID: 72)
            let providerB = WebRTCProvider(room, doc: docB, signaling: [urlOne, urlTwo], options: loopbackOptions())

            try await withE2ETeardown([providerA, providerB]) {
                try await providerA.connect()
                try await e2eEventually("provider A connected to signaling", timeout: .seconds(10)) {
                    await providerA.connected
                }
                try await providerB.connect()
                try await e2eEventually("provider B connected to signaling", timeout: .seconds(10)) {
                    await providerB.connected
                }

                // The origin: a real y-webrtc peer that only knows server 2, so it
                // can never reach A directly — only the Swift relay B bridges them.
                let peerC = try JSONLineProcess.node(script: "webrtc-peer.ts", arguments: [signalingTwo, room])
                defer { peerC.stop() }
                _ = try await peerC.waitForLine("y-webrtc peer C ready", timeout: .seconds(15)) {
                    $0["type"] as? String == "ready"
                }

                // B bridges A and C; A only ever connects to B, never to C.
                try await e2eEventually("relay B bridges A and C while A stays indirect from C", timeout: .seconds(15)) {
                    let peersA = await providerA.connectedPeers
                    let peersB = await providerB.connectedPeers
                    return peersA.count == 1 && peersB.count == 2
                }

                try await peerC.send(["type": "insertText", "text": "relay"])
                try await e2eEventually("JS edit reaches indirect Swift peer A via gossip", timeout: .seconds(15)) {
                    try docA.read { try $0.string(from: textA) == "relay" }
                }
                // A is still only directly connected to B — it received C's edit by gossip.
                #expect(await providerA.connectedPeers.count == 1)

                try await peerC.send(["type": "setAwareness", "state": ["name": "js-relay"]])
                let awarenessA = await providerA.awareness
                try await e2eEventually("JS awareness reaches indirect Swift peer A via gossip", timeout: .seconds(15)) {
                    try awarenessA.states().contains { entry in
                        (entry.state as? [String: Any])?["name"] as? String == "js-relay"
                    }
                }
            }
        }

        private func loopbackOptions() -> WebRTCProvider.Options {
            WebRTCProvider.Options(iceServers: [])
        }
    }
}
