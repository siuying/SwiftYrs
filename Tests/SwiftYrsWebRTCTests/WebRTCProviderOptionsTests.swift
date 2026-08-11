import Testing
@testable import SwiftYrsWebRTC

@Test
func webRTCProviderAppliesInboundUpdatesByDefault() {
    #expect(WebRTCProvider.Options().inboundUpdatePolicy == .apply)
}
