import Foundation
import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

extension RealNetworkE2E {
    /// Resilience of the multi-server signaling layer: `signalingStatus` aggregates
    /// across every configured server, and the provider keeps operating on the
    /// surviving server when another goes down. See issue #27.
    @Suite(.serialized)
    struct WebRTCSignalingResilienceTests {
        @Test
        func signalingStatusIsConnectingWhileNoServerIsReachable() async throws {
            // Port 1 is never listening, so the socket can never open.
            let unreachable = try #require(URL(string: "ws://127.0.0.1:1"))
            let provider = WebRTCProvider(
                "room-unreachable",
                doc: YDoc(clientID: 81),
                signaling: [unreachable],
                options: WebRTCProvider.Options(iceServers: [], initialDelay: .milliseconds(100), maxDelay: .milliseconds(200))
            )

            try await withE2ETeardown([provider]) {
                #expect(await provider.signalingStatus == .disconnected)
                try await provider.connect()
                // No server will ever open, so the aggregate stays `.connecting`.
                #expect(await provider.signalingStatus == .connecting)
            }
            #expect(await provider.signalingStatus == .disconnected)
        }

        @Test
        func signalingStaysConnectedAndOperationalWhenOneOfTwoServersIsDown() async throws {
            let serverA = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
            var serverAStopped = false
            let serverB = try JSONLineProcess.node(script: "webrtc-signaling-server.ts")
            defer {
                if !serverAStopped { serverA.stop() }
                serverB.stop()
            }
            let readyA = try await serverA.waitForLine("signaling server A ready") { $0["type"] as? String == "ready" }
            let readyB = try await serverB.waitForLine("signaling server B ready") { $0["type"] as? String == "ready" }
            let portA = try #require(readyA["port"] as? Int)
            let portB = try #require(readyB["port"] as? Int)
            let urlA = try #require(URL(string: "ws://127.0.0.1:\(portA)"))
            let urlB = try #require(URL(string: "ws://127.0.0.1:\(portB)"))
            let room = "room-one-down"

            let docP = YDoc(clientID: 91)
            let textP = try docP.text(named: "body")
            let providerP = WebRTCProvider(
                room,
                doc: docP,
                signaling: [urlA, urlB],
                options: WebRTCProvider.Options(iceServers: [], initialDelay: .milliseconds(100), maxDelay: .milliseconds(200))
            )

            let docQ = YDoc(clientID: 92)
            let textQ = try docQ.text(named: "body")
            let providerQ = WebRTCProvider(
                room,
                doc: docQ,
                signaling: [urlB],
                options: WebRTCProvider.Options(iceServers: [], initialDelay: .milliseconds(100), maxDelay: .milliseconds(200))
            )

            try await withE2ETeardown([providerP, providerQ]) {
                try await providerP.connect()
                try await e2eEventually("provider P aggregates to connected across both servers", timeout: .seconds(10)) {
                    await providerP.signalingStatus == .connected
                }

                // One server goes down; the aggregate must stay connected via server B.
                serverA.stop()
                serverAStopped = true
                #expect(await providerP.signalingStatus == .connected)

                // A later peer reachable only through the surviving server still syncs.
                try await providerQ.connect()
                try await e2eEventually("P and Q discover each other through the surviving server", timeout: .seconds(10)) {
                    let peersP = await providerP.connectedPeers
                    let peersQ = await providerQ.connectedPeers
                    return !peersP.isEmpty && !peersQ.isEmpty
                }
                #expect(await providerP.signalingStatus == .connected)

                try docQ.write { try $0.insert("survivor", into: textQ, at: 0) }
                try await e2eEventually("edit converges over the surviving server", timeout: .seconds(10)) {
                    try docP.read { try $0.string(from: textP) == "survivor" }
                }
            }
        }
    }
}
