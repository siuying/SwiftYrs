# Initial XCFramework Targets Arm64 macOS and iOS

The first XCFramework bundle will target arm64 macOS, arm64 iOS device, and arm64 iOS simulator. Intel macOS and Intel simulator slices are intentionally out of scope for the initial packaging work because the immediate goal is to prove the Rust-to-XCFramework-to-SwiftPM pipeline on current Apple hardware with a small build matrix.
