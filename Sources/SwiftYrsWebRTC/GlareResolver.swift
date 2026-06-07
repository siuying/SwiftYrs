/// Resolves "glare" — both peers offering at once. Each peer tags its offer
/// with a `glareToken` (`Date.now() + random`); on an incoming offer where we
/// already have a pending outgoing one, the higher token wins the initiator
/// role and the lower-token side rejects the incoming offer. Mirrors y-webrtc.
enum GlareResolver {
    static func shouldRejectIncomingOffer(localToken: Double?, remoteToken: Double) -> Bool {
        guard let localToken else {
            return false
        }
        return localToken > remoteToken
    }
}
