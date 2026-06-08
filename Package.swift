// swift-tools-version: 6.2

import PackageDescription

#if os(Linux)
let ffiTarget: Target = .systemLibrary(
    name: "YrsBridgeFFI",
    path: "LinuxSupport",
    pkgConfig: "yrs-bridge"
)

let hocuspocusProducts: [Product] = []

let hocuspocusTargets: [Target] = []

let webRTCProducts: [Product] = []

let webRTCTargets: [Target] = []

let packageDependencies: [Package.Dependency] = []
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

let webRTCProducts: [Product] = [
    .library(name: "SwiftYrsWebRTC", targets: ["SwiftYrsWebRTC"]),
]

let webRTCTargets: [Target] = [
    .target(
        name: "SwiftYrsWebRTC",
        dependencies: [
            "SwiftYrs",
            .product(name: "StreamWebRTC", package: "stream-video-swift-webrtc"),
        ]
    ),
    .testTarget(
        name: "SwiftYrsWebRTCTests",
        dependencies: [
            "SwiftYrsWebRTC",
            .product(name: "StreamWebRTC", package: "stream-video-swift-webrtc"),
        ],
        exclude: [
            "webrtc-signaling-server.ts",
            "webrtc-peer.ts",
        ]
    ),
    .executableTarget(
        name: "ChatExample",
        dependencies: ["SwiftYrsWebRTC"]
    ),
]

let packageDependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/GetStream/stream-video-swift-webrtc",
        from: "145.9.0"
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
    ] + hocuspocusProducts + webRTCProducts,
    dependencies: packageDependencies,
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
    ] + hocuspocusTargets + webRTCTargets,
)
