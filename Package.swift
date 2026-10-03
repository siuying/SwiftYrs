// swift-tools-version: 6.2

import PackageDescription

import Foundation

let useLocalArtifact = ProcessInfo.processInfo.environment["SWIFTYRS_USE_LOCAL_ARTIFACT"] == "1"

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
let ffiTarget: Target = useLocalArtifact
    ? .binaryTarget(name: "YrsBridgeFFI", path: "Artifacts/YrsBridge.xcframework")
    : .binaryTarget(
        name: "YrsBridgeFFI",
        url: "https://github.com/siuying/SwiftYrs/releases/download/v0.7.0/YrsBridge.xcframework.zip",
        checksum: "9f3c46d250efe012aad1ff4cc3f45bc6f4198ce3e8d5e08f9fd772c0186797ac"
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
        dependencies: ["SwiftYrsHocuspocus", "SwiftYrsTestSupport"],
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
            "SwiftYrsTestSupport",
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
        .library(name: "SwiftYrsCloudKit", targets: ["SwiftYrsCloudKit"]),
        .library(name: "SwiftYrsSQLite", targets: ["SwiftYrsSQLite"]),
    ] + hocuspocusProducts + webRTCProducts,
    dependencies: packageDependencies,
    targets: [
        ffiTarget,
        .target(name: "SwiftYrsTestSupport", path: "Tests/Support"),
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
        .target(
            name: "SwiftYrsCloudKit",
            dependencies: [
                "SwiftYrs",
                "SwiftYrsSQLite",
            ]
        ),
        .testTarget(
            name: "SwiftYrsTests",
            dependencies: ["SwiftYrs", "SwiftYrsTestSupport"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SwiftYrsCloudKitTests",
            dependencies: [
                "SwiftYrsCloudKit",
                "SwiftYrsTestSupport",
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SwiftYrsSQLiteTests",
            dependencies: ["SwiftYrsSQLite"]
        ),
    ] + hocuspocusTargets + webRTCTargets,
)
