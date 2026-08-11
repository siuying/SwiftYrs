import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

@Test
func webRTCProviderAppliesInboundUpdatesByDefault() {
    #expect(WebRTCProvider.Options().inboundUpdatePolicy == .apply)
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
