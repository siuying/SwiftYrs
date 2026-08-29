// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftYrsBinaryConsumer",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    dependencies: [
        .package(url: "https://github.com/siuying/SwiftYrs", from: "0.6.0"),
    ],
    products: [
        .executable(name: "BinaryConsumer", targets: ["BinaryConsumer"]),
    ],
    targets: [
        .executableTarget(
            name: "BinaryConsumer",
            dependencies: [.product(name: "SwiftYrs", package: "SwiftYrs")]
        ),
    ]
)
