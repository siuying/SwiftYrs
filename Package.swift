// swift-tools-version: 6.0

import PackageDescription

#if os(Linux)
let ffiTarget: Target = .systemLibrary(
    name: "YrsBridgeFFI",
    path: "LinuxSupport",
    pkgConfig: "yrs-bridge"
)
#else
let ffiTarget: Target = .binaryTarget(
    name: "YrsBridgeFFI",
    path: "Artifacts/YrsBridge.xcframework"
)
#endif

let package = Package(
    name: "SwiftYrs",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SwiftYrs", targets: ["SwiftYrs"]),
        .library(name: "SwiftYrsHocuspocus", targets: ["SwiftYrsHocuspocus"]),
    ],
    targets: [
        ffiTarget,
        .target(
            name: "SwiftYrs",
            dependencies: ["YrsBridgeFFI"]
        ),
        .target(
            name: "SwiftYrsHocuspocus",
            dependencies: ["SwiftYrs"]
        ),
        .testTarget(
            name: "SwiftYrsTests",
            dependencies: ["SwiftYrs"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SwiftYrsHocuspocusTests",
            dependencies: ["SwiftYrsHocuspocus"],
            exclude: [
                "hocuspocus-peer.ts",
                "hocuspocus-server.ts",
            ]
        ),
    ]
)
