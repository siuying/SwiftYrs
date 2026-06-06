# Local Vendoring Before Binary Artifact Releases

During development, the Swift package may vendor the locally built XCFramework so API work and tests can iterate without a release pipeline. For downstream consumption, the package should use checksumed SwiftPM binary artifact releases containing the XCFramework, so app developers do not need to build Rust or carry the native build toolchain.
