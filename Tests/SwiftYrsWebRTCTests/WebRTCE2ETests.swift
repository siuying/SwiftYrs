import Foundation
import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

extension RealNetworkE2E {
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

            try await withE2ETeardown([providerA, providerB]) {
                let syncedBox = E2EBox<Bool>()
                let syncedTask = Task { [stream = providerA.synced] in
                    for await value in stream { await syncedBox.set(value) }
                }
                defer { syncedTask.cancel() }

                try await providerA.connect()
                try await e2eEventually("provider A connected to signaling", timeout: .seconds(10)) {
                    await providerA.connected
                }
                try await providerB.connect()
                try await e2eEventually("provider B connected to signaling", timeout: .seconds(10)) {
                    await providerB.connected
                }

                try await e2eEventually("peers connected", timeout: .seconds(10)) {
                    let a = await providerA.connectedPeers
                    let b = await providerB.connectedPeers
                    return !a.isEmpty && !b.isEmpty
                }

                try docA.write { try $0.insert("hello", into: textA, at: 0) }
                try await e2eEventually("edit on A converges on B", timeout: .seconds(5)) {
                    try docB.read { try $0.string(from: textB) == "hello" }
                }

                try docB.write { try $0.insert(" world", into: textB, at: 5) }
                try await e2eEventually("edit on B converges on A", timeout: .seconds(5)) {
                    try docA.read { try $0.string(from: textA) == "hello world" }
                }

                try await e2eEventually("synced latched true", timeout: .seconds(5)) {
                    await syncedBox.value == true
                }
            }
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

            try await withE2ETeardown([providerA, providerB]) {
                let awarenessA = await providerA.awareness
                let awarenessB = await providerB.awareness
                let clientID = awarenessA.clientID
                try awarenessA.setLocalState(["name": "swift"])

                try await providerA.connect()
                try await e2eEventually("provider A connected to signaling", timeout: .seconds(10)) {
                    await providerA.connected
                }
                try await providerB.connect()
                try await e2eEventually("provider B connected to signaling", timeout: .seconds(10)) {
                    await providerB.connected
                }
                try await e2eEventually("peers connected", timeout: .seconds(10)) {
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
            }
        }

        @Test
        func threeSwiftProvidersConvergeThroughMeshGossip() async throws {
            let server = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
            defer { server.stop() }
            let ready = try await server.waitForLine("signaling server ready") { $0["type"] as? String == "ready" }
            let port = try #require(ready["port"] as? Int)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))

            let docA = YDoc(clientID: 31)
            let textA = try docA.text(named: "body")
            let providerA = WebRTCProvider("room-mesh", doc: docA, signaling: [url], options: loopbackOptions())

            let docB = YDoc(clientID: 32)
            let textB = try docB.text(named: "body")
            let providerB = WebRTCProvider("room-mesh", doc: docB, signaling: [url], options: loopbackOptions())

            let docC = YDoc(clientID: 33)
            let textC = try docC.text(named: "body")
            let providerC = WebRTCProvider("room-mesh", doc: docC, signaling: [url], options: loopbackOptions())

            try await withE2ETeardown([providerA, providerB, providerC]) {
                try await providerA.connect()
                try await e2eEventually("provider A connected to signaling", timeout: .seconds(5)) {
                    await providerA.connected
                }
                try await providerB.connect()
                try await e2eEventually("provider B connected to signaling", timeout: .seconds(5)) {
                    await providerB.connected
                }
                try await providerC.connect()
                try await e2eEventually("provider C connected to signaling", timeout: .seconds(5)) {
                    await providerC.connected
                }

                try await e2eEventually("three providers form a mesh", timeout: .seconds(10)) {
                    let peersA = await providerA.connectedPeers
                    let peersB = await providerB.connectedPeers
                    let peersC = await providerC.connectedPeers
                    return peersA.count >= 2 && peersB.count >= 2 && peersC.count >= 2
                }

                try docA.write { try $0.insert("mesh", into: textA, at: 0) }
                try await e2eEventually("edit from A converges on B and C", timeout: .seconds(10)) {
                    try docB.read { try $0.string(from: textB) == "mesh" } &&
                        docC.read { try $0.string(from: textC) == "mesh" }
                }

                try await providerA.awareness.setLocalState(["name": "mesh-a"])
                let awarenessB = await providerB.awareness
                let awarenessC = await providerC.awareness
                let clientA = await providerA.awareness.clientID
                try await e2eEventually("awareness from A converges on B and C", timeout: .seconds(10)) {
                    try awarenessB.state(for: clientA) != nil && awarenessC.state(for: clientA) != nil
                }
            }
        }

        @Test
        func providerAtMaxConnsStillAcceptsInboundConnections() async throws {
            let server = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
            defer { server.stop() }
            let ready = try await server.waitForLine("signaling server ready") { $0["type"] as? String == "ready" }
            let port = try #require(ready["port"] as? Int)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))

            let cappedDoc = YDoc(clientID: 41)
            let cappedText = try cappedDoc.text(named: "body")
            let cappedProvider = WebRTCProvider(
                "room-soft-cap",
                doc: cappedDoc,
                signaling: [url],
                options: WebRTCProvider.Options(
                    maxConns: 0,
                    iceServers: [],
                    initialDelay: .milliseconds(100),
                    maxDelay: .milliseconds(200)
                )
            )

            let peerDoc = YDoc(clientID: 42)
            let peerText = try peerDoc.text(named: "body")
            let peerProvider = WebRTCProvider("room-soft-cap", doc: peerDoc, signaling: [url], options: loopbackOptions())

            try await withE2ETeardown([cappedProvider, peerProvider]) {
                try await cappedProvider.connect()
                try await e2eEventually("cappedProvider connected to signaling", timeout: .seconds(10)) {
                    await cappedProvider.connected
                }
                try await peerProvider.connect()
                try await e2eEventually("peerProvider connected to signaling", timeout: .seconds(10)) {
                    await peerProvider.connected
                }

                try await e2eEventually("capped provider accepts inbound connection", timeout: .seconds(10)) {
                    let cappedPeers = await cappedProvider.connectedPeers
                    let peerPeers = await peerProvider.connectedPeers
                    return !cappedPeers.isEmpty && !peerPeers.isEmpty
                }

                try peerDoc.write { try $0.insert("inbound", into: peerText, at: 0) }
                try await e2eEventually("inbound peer update reaches capped provider", timeout: .seconds(10)) {
                    try cappedDoc.read { try $0.string(from: cappedText) == "inbound" }
                }
            }
        }

        @Test
        func signalingReconnectsAfterSocketDropAndDiscoversLaterPeer() async throws {
            let server = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
            defer { server.stop() }
            let ready = try await server.waitForLine("signaling server ready") { $0["type"] as? String == "ready" }
            let port = try #require(ready["port"] as? Int)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))

            let docA = YDoc(clientID: 51)
            let textA = try docA.text(named: "body")
            let providerA = WebRTCProvider(
                "room-reconnect",
                doc: docA,
                signaling: [url],
                options: WebRTCProvider.Options(iceServers: [], initialDelay: .milliseconds(100), maxDelay: .milliseconds(200))
            )

            let docB = YDoc(clientID: 52)
            let textB = try docB.text(named: "body")
            let providerB = WebRTCProvider(
                "room-reconnect",
                doc: docB,
                signaling: [url],
                options: WebRTCProvider.Options(iceServers: [], initialDelay: .milliseconds(100), maxDelay: .milliseconds(200))
            )

            try await withE2ETeardown([providerA, providerB]) {
                try await providerA.connect()
                try await e2eEventually("provider A connected to signaling", timeout: .seconds(10)) {
                    await providerA.connected
                }

                try await server.send(["type": "closeClients"])
                try await e2eEventually("provider A reconnects to signaling", timeout: .seconds(10)) {
                    await providerA.connected
                }

                try await providerB.connect()
                try await e2eEventually("later peer discovered after reconnect", timeout: .seconds(10)) {
                    let peersA = await providerA.connectedPeers
                    let peersB = await providerB.connectedPeers
                    return !peersA.isEmpty && !peersB.isEmpty
                }

                try docB.write { try $0.insert("recovered", into: textB, at: 0) }
                try await e2eEventually("later peer update reaches reconnected provider", timeout: .seconds(10)) {
                    try docA.read { try $0.string(from: textA) == "recovered" }
                }
            }
        }

        @Test
        func providersDiscoverPeersThroughAnyConfiguredSignalingServer() async throws {
            let serverA = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
            let serverB = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
            defer {
                serverA.stop()
                serverB.stop()
            }
            let readyA = try await serverA.waitForLine("signaling server A ready") { $0["type"] as? String == "ready" }
            let readyB = try await serverB.waitForLine("signaling server B ready") { $0["type"] as? String == "ready" }
            let portA = try #require(readyA["port"] as? Int)
            let portB = try #require(readyB["port"] as? Int)
            let urlA = try #require(URL(string: "ws://127.0.0.1:\(portA)"))
            let urlB = try #require(URL(string: "ws://127.0.0.1:\(portB)"))

            let docA = YDoc(clientID: 61)
            let textA = try docA.text(named: "body")
            let providerA = WebRTCProvider("room-multi-server", doc: docA, signaling: [urlA, urlB], options: loopbackOptions())

            let docB = YDoc(clientID: 62)
            let textB = try docB.text(named: "body")
            let providerB = WebRTCProvider("room-multi-server", doc: docB, signaling: [urlB], options: loopbackOptions())

            try await withE2ETeardown([providerA, providerB]) {
                try await providerA.connect()
                try await e2eEventually("provider A connected to signaling", timeout: .seconds(10)) {
                    await providerA.connected
                }
                try await providerB.connect()
                try await e2eEventually("provider B connected to signaling", timeout: .seconds(10)) {
                    await providerB.connected
                }

                try await e2eEventually("providers discover each other through shared signaling server", timeout: .seconds(10)) {
                    let peersA = await providerA.connectedPeers
                    let peersB = await providerB.connectedPeers
                    return !peersA.isEmpty && !peersB.isEmpty
                }

                try docA.write { try $0.insert("server-b", into: textA, at: 0) }
                try await e2eEventually("multi-server discovered peer receives update", timeout: .seconds(10)) {
                    try docB.read { try $0.string(from: textB) == "server-b" }
                }
            }
        }

        private func loopbackOptions() -> WebRTCProvider.Options {
            // No STUN: host candidates over loopback are enough for two local peers.
            WebRTCProvider.Options(iceServers: [])
        }
    }
}
