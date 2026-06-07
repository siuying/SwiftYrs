# WebRTC provider emulates simple-peer's signaling dialect over raw libwebrtc

The `WebRTCProvider` targets wire-level interop with browser `y-webrtc` peers, which use `simple-peer` on top of `RTCPeerConnection`. Because we build on raw Google libwebrtc (via the `StreamWebRTC` XCFramework) rather than a Swift port of simple-peer, the provider marshals libwebrtc's separate SDP and trickled ICE callbacks into simple-peer-shaped `signal` objects (`{type:'offer'|'answer', sdp}`, `{type:'candidate', candidate:{candidate, sdpMid, sdpMLineIndex}}`) wrapped in y-webrtc's `{type:'signal', from, to, token, signal}` envelope, and applies inbound signals symmetrically.

## Considered Options

- **Raw libwebrtc + a simple-peer compatibility shim (chosen).** Full ICE/SDP/NAT traversal and proven browser interop, at the cost of hand-maintaining the signal translation and matching simple-peer's defaults (trickle ICE, `negotiated:false` in-band data channel, glare resolution via `glareToken`).
- **Pure-Swift WebRTC (`swift-webrtc`).** Rejected: it implements ICE Lite with no SDP negotiation and leaves UDP to the caller, so two NATed peers cannot connect and it cannot interoperate with a browser `RTCPeerConnection`.
- **Port `simple-peer` to Swift.** Rejected: it wraps the same libwebrtc primitives we already have; porting it adds a maintenance surface without removing the translation problem.

## Consequences

- The translation layer is the interop contract: changes to simple-peer's signal shapes or defaults can silently break browser interop, so it is covered by the Swift↔JS E2E suite (real `y-webrtc` peer under node) and not just unit tests.
- `transceiverRequest`/`renegotiate` signals are ignored; the connection is data-channel-only.
