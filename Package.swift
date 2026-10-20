// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Unwine",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Unwine",
            path: "Sources/Unwine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
