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

let packageDependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/stephencelis/SQLite.swift",
        from: "0.15.4"
    ),
]
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
        dependencies: [
            "SwiftYrsSQLite",
            "SwiftYrsWebRTC",
            .product(name: "SQLite", package: "SQLite.swift"),
        ]
    ),
]

let packageDependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/stephencelis/SQLite.swift",
        from: "0.15.4"
    ),
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
        .library(name: "SwiftYrsSQLite", targets: ["SwiftYrsSQLite"]),
    ] + hocuspocusProducts + webRTCProducts,
    dependencies: packageDependencies,
    targets: [
        ffiTarget,
        .target(
            name: "SwiftYrs",
            dependencies: ["YrsBridgeFFI"]
        ),
        .target(
            name: "SwiftYrsSQLite",
            dependencies: [
                "SwiftYrs",
                .product(name: "SQLite", package: "SQLite.swift"),
            ]
        ),
        .testTarget(
            name: "SwiftYrsTests",
            dependencies: ["SwiftYrs"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SwiftYrsSQLiteTests",
            dependencies: ["SwiftYrsSQLite"]
        ),
    ] + hocuspocusTargets + webRTCTargets,
)
