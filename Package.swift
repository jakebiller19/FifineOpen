// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FifineDeck",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FifineDeck",
            path: "Sources/FifineDeck"
        ),
        // Covers the parts with real logic in them — the multi-key span
        // layout, config validation, and that every widget face renders at
        // the size it claims. Nothing here touches the network, the deck, or
        // the credentials file.
        .testTarget(
            name: "FifineDeckTests",
            dependencies: ["FifineDeck"],
            path: "Tests/FifineDeckTests"
        ),
    ]
)
