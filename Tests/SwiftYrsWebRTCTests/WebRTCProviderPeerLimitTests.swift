import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

@Test
func defaultPeerLimitAllowsInboundOffers() async throws {
    let provider = WebRTCProvider(
        "unlimited-peers",
        doc: YDoc(),
        signaling: [],
        options: .init(iceServers: [])
    )

    try await provider.connect()
    await provider.handleSignal(from: "peer-a", token: 1, signal: .offer(sdp: "v=0"))
    await provider.handleSignal(from: "peer-b", token: 2, signal: .offer(sdp: "v=0"))

    #expect(await provider.peerCount == 2)
    await provider.destroy()
}

@Test
func peerLimitRefusesNewInboundOffersAtCapacity() async throws {
    let provider = WebRTCProvider(
        "limited-peers",
        doc: YDoc(),
        signaling: [],
        options: .init(maxPeers: 1, iceServers: [])
    )

    try await provider.connect()
    await provider.handleSignal(from: "peer-a", token: 1, signal: .offer(sdp: "v=0"))
    await provider.handleSignal(from: "peer-b", token: 2, signal: .offer(sdp: "v=0"))

    #expect(await provider.peerCount == 1)
    await provider.destroy()
}

@Test
func peerLimitAllowsAnExistingPeerToReofferAtCapacity() async throws {
    let provider = WebRTCProvider(
        "limited-reoffer",
        doc: YDoc(),
        signaling: [],
        options: .init(maxPeers: 1, iceServers: [])
    )

    try await provider.connect()
    await provider.handleSignal(from: "peer-a", token: 1, signal: .offer(sdp: "v=0"))
    let firstRecord = try #require(await provider.peerRecordIdentifier(for: "peer-a"))
    await provider.handleSignal(from: "peer-a", token: 2, signal: .offer(sdp: "v=0"))

    #expect(await provider.peerCount == 1)
    #expect(await provider.peerRecordIdentifier(for: "peer-a") != firstRecord)
    await provider.destroy()
}

@Test
func peerLimitRefusesRetriesWithoutGrowingProviderState() async throws {
    let provider = WebRTCProvider(
        "limited-retries",
        doc: YDoc(),
        signaling: [],
        options: .init(maxPeers: 1, iceServers: [])
    )

    try await provider.connect()
    await provider.handleSignal(from: "peer-a", token: 1, signal: .offer(sdp: "v=0"))
    for token in 2...10 {
        await provider.handleSignal(from: "refused-peer", token: Double(token), signal: .offer(sdp: "v=0"))
    }

    #expect(await provider.peerCount == 1)
    await provider.destroy()
}

@Test
func peerLimitPreventsOutboundConnectionsPastCapacity() async throws {
    let provider = WebRTCProvider(
        "limited-outbound",
        doc: YDoc(),
        signaling: [],
        options: .init(maxConns: 10, maxPeers: 1, iceServers: [])
    )

    try await provider.connect()
    await provider.handleAnnounce(from: "peer-a")
    await provider.handleAnnounce(from: "peer-b")

    #expect(await provider.peerCount == 1)
    await provider.destroy()
}
