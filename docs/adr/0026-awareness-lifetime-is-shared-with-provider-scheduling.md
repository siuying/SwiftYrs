# Awareness lifetime is shared with provider scheduling

`YAwareness` tracks the time of accepted updates and exposes a synchronous `checkTimeouts()`. Hocuspocus and WebRTC schedule checks on their own actors while running. Custom Connection Providers must schedule checks on the actor or serial queue that owns awareness. Core awareness does not create a task that could access its native handle from another executor.

Defaults follow `y-protocols` 1.0.7: check every 3 seconds, renew non-null local state after 15 seconds, and remove remote states after 30 seconds. `YAwareness.Timing` and an injectable monotonic `now` function support tests without waiting for these intervals. Provider tasks sleep without retaining their actor, and cancellation plus a generation ID prevents stopped tasks from checking after disconnect, destroy, or restart.

Yrs stores clocks and timestamps, but the existing Shim ABI exposes neither timestamp access nor automatic expiry. Swift observes accepted native updates to track time, including unchanged state with an increased clock. Replayed updates do not refresh time. For expiry, Swift applies a batched null update at the existing remote clocks. Native `remove_state` increments remote clocks, which would reject a peer's next renewal. Expiry emits change and update events with `YAwarenessChange.origin` set to `"timeout"`. This requires no Binary Artifact Release.

Mutations inside user callbacks reconcile active clocks before and after the native call, since Yrs suppresses observers of the same kind during callback delivery. Nested ordinary mutations receive no timeout origin.

Sources inspected for this decision:

- [y-protocols 1.0.7 awareness.js](https://unpkg.com/y-protocols@1.0.7/awareness.js)
- [Hocuspocus provider 4.7.0 HocuspocusProviderWebsocket.ts](https://unpkg.com/@hocuspocus/provider@4.7.0/src/HocuspocusProviderWebsocket.ts), whose default receive timeout is 30 seconds and expects awareness renewal traffic.
- [Hocuspocus server 4.7.0 ClientConnection.ts](https://unpkg.com/@hocuspocus/server@4.7.0/src/ClientConnection.ts), whose idle check closes authenticated connections with code 4408 after the configured timeout, 60 seconds by default.
