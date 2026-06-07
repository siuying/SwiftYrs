import StreamWebRTC

/// A STUN/TURN server, wrapping libwebrtc's `RTCIceServer` so the ObjC type stays
/// out of the public API.
public struct WebRTCIceServer: Sendable, Equatable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    var rtcIceServer: RTCIceServer {
        RTCIceServer(urlStrings: urls, username: username, credential: credential)
    }
}

public extension [WebRTCIceServer] {
    /// Google's public STUN server, y-webrtc's default.
    static var defaultSTUN: [WebRTCIceServer] {
        [WebRTCIceServer(urls: ["stun:stun.l.google.com:19302"])]
    }
}
