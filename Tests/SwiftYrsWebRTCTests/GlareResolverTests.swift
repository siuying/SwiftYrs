import Testing
@testable import SwiftYrsWebRTC

@Test
func glareRejectsIncomingOfferWhenLocalTokenWins() {
    #expect(GlareResolver.shouldRejectIncomingOffer(localToken: 100, remoteToken: 50))
}

@Test
func glareAcceptsIncomingOfferWhenRemoteTokenWins() {
    #expect(!GlareResolver.shouldRejectIncomingOffer(localToken: 50, remoteToken: 100))
}

@Test
func glareAcceptsIncomingOfferWhenNoLocalToken() {
    #expect(!GlareResolver.shouldRejectIncomingOffer(localToken: nil, remoteToken: 100))
}

@Test
func glareAcceptsIncomingOfferOnTie() {
    // Equal tokens are vanishingly unlikely (Date.now()+random); y-webrtc accepts.
    #expect(!GlareResolver.shouldRejectIncomingOffer(localToken: 100, remoteToken: 100))
}
