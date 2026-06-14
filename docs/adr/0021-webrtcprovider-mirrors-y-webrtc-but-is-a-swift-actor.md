# WebRTCProvider mirrors y-webrtc's vocabulary but is a Swift actor with an explicit async lifecycle

`WebRTCProvider` borrows y-webrtc's public vocabulary and semantics — `(roomName, doc, options)` construction, an internally-created `awareness`, `connect`/`disconnect`/`destroy` lifecycle, and `status`/`synced`/`peers` observation — but it is a Swift `actor` with an async, explicit lifecycle rather than a faithful port of y-webrtc's synchronous, auto-connecting `Observable` API. The goal is "feels like y-webrtc" at the level of names and behavior, not a literal API transliteration.

## Considered Options

- **Actor with y-webrtc-flavored naming (chosen).** Keeps Swift 6 strict-concurrency safety (libwebrtc's threaded delegate callbacks marshal into actor isolation) while staying recognizable to y-webrtc users.
- **Faithful synchronous reference type** (`@MainActor` class or internally-queued `final class`) with constructor auto-connect, synchronous getters, and EventEmitter-style `.on()`. Rejected: it reverses the actor model and couples a networking provider to MainActor or to hand-rolled internal locking, for surface-level API fidelity.

## Consequences — deliberate divergences from y-webrtc (so future readers don't "fix" them)

- **No constructor auto-connect.** An actor `init` cannot run async/throwing work, so the caller must `await connect()` explicitly. The `connect: Bool` option is therefore dropped.
- **`signaling` is required, with no public defaults.** y-webrtc defaults to public relays; we refuse to point users at a third party's box (operational safety, and parity with how `HocuspocusProvider` requires an explicit URL).
- **Observation is `AsyncStream`, not EventEmitter `.on()`.** Current state is readable via `connected` / `connectedPeers` getters since streams do not replay to late subscribers.
- **`status` is a 3-state enum** (`connecting`/`connected`/`disconnected`) rather than y-webrtc's `{connected: Bool}`.
- **`peers` carries `{added, removed, webrtcPeers}`** — `bcPeers` is dropped (no BroadcastChannel equivalent in Swift).
- **`room` is private** (implementation detail) and **`destroy()` must be called explicitly** (an actor `deinit` cannot run isolated teardown; `deinit` is best-effort only).
- A provider-created `awareness` is fully torn down on `destroy()`; a caller-supplied one is left intact (`ownsAwareness`).
- Sync-protocol choreography is delegated to core `YSyncEngine`; this internal extraction does not change the provider's public actor shape.
