@preconcurrency import StreamWebRTC

/// Process-lifetime libwebrtc factory. `RTCInitializeSSL()` is called once and
/// never torn down (no `RTCCleanupSSL()`): the factory outlives any individual
/// provider, matching how libwebrtc expects global SSL state to be managed.
/// libwebrtc's factory is internally thread-safe, so the immutable singleton is
/// `nonisolated(unsafe)`.
enum WebRTCFactory {
    nonisolated(unsafe) static let shared: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()
}
