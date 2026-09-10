// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Storybird",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StorybirdCore", targets: ["StorybirdCore"]),
        .executable(name: "Storybird", targets: ["Storybird"]),
        .executable(name: "StorybirdMCP", targets: ["StorybirdMCP"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        ),
    ],
    targets: [
        .target(
            name: "StorybirdCore",
            path: "Sources/StorybirdCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags([
                    "-Xfrontend", "-enable-actor-data-race-checks",
                ], .when(configuration: .debug)),
            ]
        ),
        .executableTarget(
            name: "Storybird",
            dependencies: [
                "StorybirdCore",
                "StorybirdMCPKit",
            ],
            path: "Sources/Storybird",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags([
                    "-Xfrontend", "-enable-actor-data-race-checks",
                ], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "StorybirdMCPKit",
            dependencies: [
                "StorybirdCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/StorybirdMCPKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags([
                    "-Xfrontend", "-enable-actor-data-race-checks",
                ], .when(configuration: .debug)),
            ]
        ),
        .executableTarget(
            name: "StorybirdMCP",
            dependencies: ["StorybirdMCPKit"],
            path: "Sources/StorybirdMCP",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags([
                    "-Xfrontend", "-enable-actor-data-race-checks",
                ], .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "StorybirdCoreTests",
            dependencies: ["StorybirdCore"],
            path: "Tests/StorybirdCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "StorybirdTests",
            dependencies: [
                "Storybird",
                "StorybirdCore",
                "StorybirdMCPKit",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Tests/StorybirdTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
