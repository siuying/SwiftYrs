// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftYrs",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SwiftYrs", targets: ["SwiftYrs"]),
    ],
    targets: [
        .binaryTarget(
            name: "YrsBridgeFFI",
            path: "Artifacts/YrsBridge.xcframework"
        ),
        .target(
            name: "SwiftYrs",
            dependencies: ["YrsBridgeFFI"]
        ),
        .testTarget(
            name: "SwiftYrsTests",
            dependencies: ["SwiftYrs"],
            resources: [.process("Fixtures")]
        ),
    ]
)
