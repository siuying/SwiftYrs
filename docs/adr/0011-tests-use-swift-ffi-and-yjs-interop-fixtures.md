# Tests Use Swift, FFI, and Yjs Interop Fixtures

The Swift binding test suite will use three layers of evidence: Swift API tests for ergonomics and lifetime behavior, Rust/Yrs or yffi-level fixtures for native bridge behavior, and JavaScript Yjs interop fixtures for binary/protocol compatibility. JavaScript Yjs is the compatibility authority for encoded updates, state vectors, awareness payloads, and sync protocol messages.
