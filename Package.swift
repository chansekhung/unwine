// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Decant",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Decant",
            path: "Sources/Decant",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
