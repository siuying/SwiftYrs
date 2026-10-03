import Foundation
import SwiftYrsTestSupport
import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

extension RealNetworkE2E {
    @Suite(.serialized)
    struct WebRTCE2ETests {
        @Test
        func twoSwiftProvidersSyncADocumentOverADataChannel() async throws {
            try await withE2EProcesses { processes in
                let server = try processes.node(script: "webrtc-signaling-server.ts")
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
                    try await e2eEventually("provider A connected to signaling", timeout: .seconds(30)) {
                        await providerA.connected
                    }
                    try await providerB.connect()
                    try await e2eEventually("provider B connected to signaling", timeout: .seconds(30)) {
                        await providerB.connected
                    }

                    try await e2eEventually("peers connected", timeout: .seconds(30)) {
                        let a = await providerA.connectedPeers
                        let b = await providerB.connectedPeers
                        return !a.isEmpty && !b.isEmpty
                    }

                    try docA.write { try $0.insert("hello", into: textA, at: 0) }
                    try await e2eEventually("edit on A converges on B", timeout: .seconds(30)) {
                        try docB.read { try $0.string(from: textB) == "hello" }
                    }

                    try docB.write { try $0.insert(" world", into: textB, at: 5) }
                    try await e2eEventually("edit on B converges on A", timeout: .seconds(30)) {
                        try docA.read { try $0.string(from: textA) == "hello world" }
                    }

                    try await e2eEventually("synced latched true", timeout: .seconds(30)) {
                        await syncedBox.value == true
                    }
                }
            }
        }

        @Test
        func discardInboundUpdatesKeepsAuthorDocumentReadOnly() async throws {
            try await withE2EProcesses { processes in
                let server = try processes.node(script: "webrtc-signaling-server.ts")
                let ready = try await server.waitForLine("signaling server ready") { $0["type"] as? String == "ready" }
                let port = try #require(ready["port"] as? Int)
                let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))

                let authorDoc = YDoc(clientID: 71)
                let authorText = try authorDoc.text(named: "body")
                let handled = AsyncStream.makeStream(of: Data.self)
                let witness = YDoc(clientID: 73)
                let authorProvider = WebRTCProvider(
                    "room-read-only",
                    doc: authorDoc,
                    signaling: [url],
                    options: WebRTCProvider.Options(iceServers: [], inboundUpdatePolicy: .discard),
                    testHooks: .init(onSyncMessageHandled: { payload in
                        guard let messages = try? YSyncMessage.decodePayload(payload) else { return }
                        for message in messages {
                            switch message {
                            case let .syncStep2(update, _), let .update(update, _):
                                handled.continuation.yield(update.data)
                            default: break
                            }
                        }
                    })
                )

                let peerDoc = YDoc(clientID: 72)
                let peerText = try peerDoc.text(named: "body")
                try peerDoc.write { try $0.insert("step two", into: peerText, at: 0) }
                let peerProvider = WebRTCProvider("room-read-only", doc: peerDoc, signaling: [url], options: loopbackOptions())

                try await withE2ETeardown([authorProvider, peerProvider]) {
                    try await authorProvider.connect()
                    try await peerProvider.connect()
                    try await e2eEventually("peers connected", timeout: .seconds(30)) {
                        let authorPeers = await authorProvider.connectedPeers
                        let peerPeers = await peerProvider.connectedPeers
                        return authorPeers.count == 1 && peerPeers.count == 1
                    }

                    try await awaitHandledText(handled.stream, witness: witness, expected: "step two")
                    try authorDoc.read { try #expect($0.string(from: authorText).isEmpty) }

                    try peerDoc.write { try $0.insert(" update", into: peerText, at: 8) }
                    try await awaitHandledText(handled.stream, witness: witness, expected: "step two update")
                    try authorDoc.read { try #expect($0.string(from: authorText).isEmpty) }

                    let peerAwareness = await peerProvider.awareness
                    try peerAwareness.setLocalState(["name": "reader"])
                    let authorAwareness = await authorProvider.awareness
                    try await e2eEventually("peer awareness reaches author", timeout: .seconds(30)) {
                        try (authorAwareness.state(for: peerAwareness.clientID) as? [String: Any])?["name"] as? String == "reader"
                    }

                    try authorDoc.write { try $0.insert("author", into: authorText, at: 0) }
                    try await e2eEventually("author update reaches peer", timeout: .seconds(30)) {
                        try peerDoc.read { try $0.string(from: peerText) == "authorstep two update" }
                    }

                    for _ in 0..<10 {
                        let end = try peerDoc.read { try UInt32($0.string(from: peerText).utf16.count) }
                        try peerDoc.write { try $0.insert("!", into: peerText, at: end) }
                    }
                    try await awaitHandledText(handled.stream, witness: witness, expected: "authorstep two update!!!!!!!!!!")
                    try authorDoc.read { try #expect($0.string(from: authorText) == "author") }
                    #expect(await authorProvider.connectedPeers.count == 1)
                    #expect(await peerProvider.connectedPeers.count == 1)
                }
            }
        }

        @Test(arguments: [false, true])
        func stoppingBroadcastsLocalAwarenessRemoval(destroy: Bool) async throws {
            try await withE2EProcesses { processes in
                let server = try processes.node(script: "webrtc-signaling-server.ts")
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
                    try await e2eEventually("provider A connected to signaling", timeout: .seconds(30)) {
                        await providerA.connected
                    }
                    try await providerB.connect()
                    try await e2eEventually("provider B connected to signaling", timeout: .seconds(30)) {
                        await providerB.connected
                    }
                    try await e2eEventually("peers connected", timeout: .seconds(30)) {
                        let a = await providerA.connectedPeers
                        let b = await providerB.connectedPeers
                        return !a.isEmpty && !b.isEmpty
                    }

                    try await e2eEventually("awareness state received by B", timeout: .seconds(30)) {
                        try awarenessB.state(for: clientID) != nil
                    }

                    if destroy { await providerA.destroy() } else { await providerA.disconnect() }

                    try await e2eEventually("awareness state removed after A stops", timeout: .seconds(30)) {
                        try awarenessB.state(for: clientID) == nil
                    }
                    _ = await providerB.peerCount
                    #expect(try awarenessB.encodeUpdate(for: [11]).data == Data([1, 11, 2, 4] + Array("null".utf8)))
                }
            }
        }

        @Test
        func threeSwiftProvidersConvergeThroughMeshGossip() async throws {
            try await withE2EProcesses { processes in
                let server = try processes.node(script: "webrtc-signaling-server.ts")
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
                    try await e2eEventually("provider A connected to signaling", timeout: .seconds(30)) {
                        await providerA.connected
                    }
                    try await providerB.connect()
                    try await e2eEventually("provider B connected to signaling", timeout: .seconds(30)) {
                        await providerB.connected
                    }
                    try await providerC.connect()
                    try await e2eEventually("provider C connected to signaling", timeout: .seconds(30)) {
                        await providerC.connected
                    }

                    try await e2eEventually("three providers form a mesh", timeout: .seconds(30)) {
                        let peersA = await providerA.connectedPeers
                        let peersB = await providerB.connectedPeers
                        let peersC = await providerC.connectedPeers
                        return peersA.count >= 2 && peersB.count >= 2 && peersC.count >= 2
                    }

                    try docA.write { try $0.insert("mesh", into: textA, at: 0) }
                    try await e2eEventually("edit from A converges on B and C", timeout: .seconds(30)) {
                        try docB.read { try $0.string(from: textB) == "mesh" } &&
                            docC.read { try $0.string(from: textC) == "mesh" }
                    }

                    try await providerA.awareness.setLocalState(["name": "mesh-a"])
                    let awarenessB = await providerB.awareness
                    let awarenessC = await providerC.awareness
                    let clientA = await providerA.awareness.clientID
                    try await e2eEventually("awareness from A converges on B and C", timeout: .seconds(30)) {
                        try awarenessB.state(for: clientA) != nil && awarenessC.state(for: clientA) != nil
                    }
                }
            }
        }

        @Test
        func providerAtMaxConnsStillAcceptsInboundConnections() async throws {
            try await withE2EProcesses { processes in
                let server = try processes.node(script: "webrtc-signaling-server.ts")
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
                    try await e2eEventually("cappedProvider connected to signaling", timeout: .seconds(30)) {
                        await cappedProvider.connected
                    }
                    try await peerProvider.connect()
                    try await e2eEventually("peerProvider connected to signaling", timeout: .seconds(30)) {
                        await peerProvider.connected
                    }

                    try await e2eEventually("capped provider accepts inbound connection", timeout: .seconds(30)) {
                        let cappedPeers = await cappedProvider.connectedPeers
                        let peerPeers = await peerProvider.connectedPeers
                        return !cappedPeers.isEmpty && !peerPeers.isEmpty
                    }

                    try peerDoc.write { try $0.insert("inbound", into: peerText, at: 0) }
                    try await e2eEventually("inbound peer update reaches capped provider", timeout: .seconds(30)) {
                        try cappedDoc.read { try $0.string(from: cappedText) == "inbound" }
                    }
                }
            }
        }

        @Test
        func signalingReconnectsAfterSocketDropAndDiscoversLaterPeer() async throws {
            try await withE2EProcesses { processes in
                let server = try processes.node(script: "webrtc-signaling-server.ts")
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
                    try await e2eEventually("provider A connected to signaling", timeout: .seconds(30)) {
                        await providerA.connected
                    }

                    try await server.send(["type": "closeClients"])
                    try await e2eEventually("provider A reconnects to signaling", timeout: .seconds(30)) {
                        await providerA.connected
                    }

                    try await providerB.connect()
                    try await e2eEventually("later peer discovered after reconnect", timeout: .seconds(30)) {
                        let peersA = await providerA.connectedPeers
                        let peersB = await providerB.connectedPeers
                        return !peersA.isEmpty && !peersB.isEmpty
                    }

                    try docB.write { try $0.insert("recovered", into: textB, at: 0) }
                    try await e2eEventually("later peer update reaches reconnected provider", timeout: .seconds(30)) {
                        try docA.read { try $0.string(from: textA) == "recovered" }
                    }
                }
            }
        }

        @Test
        func providersDiscoverPeersThroughAnyConfiguredSignalingServer() async throws {
            try await withE2EProcesses { processes in
                let serverA = try processes.node(script: "webrtc-signaling-server.ts")
                let serverB = try processes.node(script: "webrtc-signaling-server.ts")
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
                    try await e2eEventually("provider A connected to signaling", timeout: .seconds(30)) {
                        await providerA.connected
                    }
                    try await providerB.connect()
                    try await e2eEventually("provider B connected to signaling", timeout: .seconds(30)) {
                        await providerB.connected
                    }

                    try await e2eEventually("providers discover each other through shared signaling server", timeout: .seconds(30)) {
                        let peersA = await providerA.connectedPeers
                        let peersB = await providerB.connectedPeers
                        return !peersA.isEmpty && !peersB.isEmpty
                    }

                    try docA.write { try $0.insert("server-b", into: textA, at: 0) }
                    try await e2eEventually("multi-server discovered peer receives update", timeout: .seconds(30)) {
                        try docB.read { try $0.string(from: textB) == "server-b" }
                    }
                }
            }
        }

        private func loopbackOptions() -> WebRTCProvider.Options {
            // No STUN: host candidates over loopback are enough for two local peers.
            WebRTCProvider.Options(iceServers: [])
        }
    }
}

// Applying acknowledged wire updates to a separate document proves all expected
// content was handled before asserting that the discard provider stayed unchanged.
private func awaitHandledText(_ stream: AsyncStream<Data>, witness: YDoc, expected: String) async throws {
    try await withTestTimeout {
        let text = try witness.text(named: "body")
        for await bytes in stream {
            try witness.apply(YUpdate(bytes, encoding: .v1))
            if try witness.read({ try $0.string(from: text) == expected }) { return }
        }
        throw CancellationError()
    }
}
