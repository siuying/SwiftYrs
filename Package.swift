// swift-tools-version: 6.0

import PackageDescription

#if os(Linux)
let ffiTarget: Target = .systemLibrary(
    name: "YrsBridgeFFI",
    path: "LinuxSupport",
    pkgConfig: "yrs-bridge"
)

let hocuspocusProducts: [Product] = []

let hocuspocusTargets: [Target] = []
#else
let ffiTarget: Target = .binaryTarget(
    name: "YrsBridgeFFI",
    path: "Artifacts/YrsBridge.xcframework"
)

let hocuspocusProducts: [Product] = [
    .library(name: "SwiftYrsHocuspocus", targets: ["SwiftYrsHocuspocus"]),
]

let hocuspocusTargets: [Target] = [
    .target(
        name: "SwiftYrsHocuspocus",
        dependencies: ["SwiftYrs"]
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
#endif

let package = Package(
    name: "SwiftYrs",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .custom("linux", versionString: "1"),
    ],
    products: [
        .library(name: "SwiftYrs", targets: ["SwiftYrs"]),
    ] + hocuspocusProducts,
    targets: [
        ffiTarget,
        .target(
            name: "SwiftYrs",
            dependencies: ["YrsBridgeFFI"]
        ),
        .testTarget(
            name: "SwiftYrsTests",
            dependencies: ["SwiftYrs"],
            resources: [.process("Fixtures")]
        ),
    ] + hocuspocusTargets,
)
