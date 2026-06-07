import Testing

/// Serialized parent for the heavy real-network E2E/interop suites. Each of these
/// suites spawns node signaling-server and peer subprocesses and drives real
/// ICE/DTLS negotiation. Swift Testing's `.serialized` only orders tests *within*
/// a suite, so without a shared parent the suites run concurrently and starve one
/// another's negotiation — sub-second tests balloon to 30s+ as they creep toward
/// their `e2eEventually` timeouts. Nesting them here makes the suites run one at a
/// time while the fast unit suites stay parallel.
@Suite(.serialized)
enum RealNetworkE2E {}
