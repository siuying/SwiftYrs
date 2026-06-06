// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftYrsBinaryConsumer",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "BinaryConsumer", targets: ["BinaryConsumer"]),
    ],
    targets: [
        .binaryTarget(
            name: "YrsBridgeFFI",
            path: "../../Artifacts/YrsBridge.xcframework"
        ),
        .executableTarget(
            name: "BinaryConsumer",
            dependencies: ["YrsBridgeFFI"]
        ),
    ]
)
