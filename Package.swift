// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dotMD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "dotMD",
            path: "Sources/dotMD",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
