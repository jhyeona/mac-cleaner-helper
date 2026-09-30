// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacCleanHelper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacCleanHelper", targets: ["MacCleanHelper"])
    ],
    targets: [
        .executableTarget(
            name: "MacCleanHelper",
            path: "Sources/MacCleanHelper",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "MacCleanHelperTests",
            dependencies: ["MacCleanHelper"],
            path: "Tests/MacCleanHelperTests"
        )
    ]
)
