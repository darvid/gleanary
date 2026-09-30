// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sink",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Sink", targets: ["Sink"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(
            url: "https://github.com/SwiftGraphs/Grape.git",
            revision: "bdfad750d2a973af48159119eaf90530d0e30ea7"
        ),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9"),
        .package(
            url: "https://github.com/arraypress/swift-youtube-metadata.git",
            revision: "536cf888beae597c83cd18604e64d4486c21f2ba"
        ),
        .package(
            url: "https://github.com/alexeichhorn/YouTubeKit.git",
            revision: "e5b7d0396ce12bf3444f0d209e8436c83373b7af"
        ),
    ],
    targets: [
        .executableTarget(
            name: "Sink",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ForceSimulation", package: "Grape"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "YouTubeTranscript", package: "swift-youtube-metadata"),
                .product(name: "YouTubeKit", package: "YouTubeKit"),
            ],
            path: "Sink",
            exclude: ["Sink.entitlements", "Info.plist"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SinkTests",
            dependencies: ["Sink", .product(name: "GRDB", package: "GRDB.swift")],
            path: "SinkTests"
        ),
    ]
)
