@preconcurrency import StreamWebRTC

/// libwebrtc factory construction. `RTCInitializeSSL()` runs once per process;
/// each `WebRTCProvider` owns its own `RTCPeerConnectionFactory` to isolate
/// factory lifetime and reduce cross-provider libwebrtc thread contention during
/// teardown (especially in serialized real-network E2E runs).
enum WebRTCFactory {
    private static let initializeSSL: Void = {
        RTCInitializeSSL()
        return ()
    }()

    static func makePeerConnectionFactory() -> RTCPeerConnectionFactory {
        _ = initializeSSL
        return RTCPeerConnectionFactory()
    }
}
