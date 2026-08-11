import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

@Test
func webRTCProviderAppliesInboundUpdatesByDefault() {
    #expect(WebRTCProvider.Options().inboundUpdatePolicy == .apply)
}

@Test
func webRTCProviderLeavesPeerLimitUnlimitedByDefault() {
    #expect(WebRTCProvider.Options().maxPeers == nil)
}

@Test
func providerExposesConfiguredPeerLimit() {
    let provider = WebRTCProvider(
        "options",
        doc: YDoc(),
        signaling: [],
        options: .init(maxPeers: 4, iceServers: [])
    )

    #expect(provider.maxPeers == 4)
}

@Test(arguments: [
    WebRTCProvider.Options.InboundUpdatePolicy.apply,
    .discard,
])
func providerExposesConfiguredInboundUpdatePolicy(
    _ inboundUpdatePolicy: WebRTCProvider.Options.InboundUpdatePolicy
) {
    let provider = WebRTCProvider(
        "options",
        doc: YDoc(),
        signaling: [],
        options: .init(iceServers: [], inboundUpdatePolicy: inboundUpdatePolicy)
    )

    #expect(provider.inboundUpdatePolicy == inboundUpdatePolicy)
}
