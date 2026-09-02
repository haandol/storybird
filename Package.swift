// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Storybird",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StorybirdCore", targets: ["StorybirdCore"]),
        .executable(name: "Storybird", targets: ["Storybird"]),
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
            dependencies: ["StorybirdCore"],
            path: "Sources/Storybird",
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
            dependencies: ["Storybird", "StorybirdCore"],
            path: "Tests/StorybirdTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
