@preconcurrency import StreamWebRTC

/// libwebrtc factory construction. `RTCInitializeSSL()` runs once per process;
/// each `WebRTCProvider` owns its own `RTCPeerConnectionFactory` so peer
/// connection teardown stays on that provider's conn queues instead of racing
/// a process-wide factory shared across actor threads.
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
