// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Unwine",
    platforms: [.macOS(.v15)],   // the same as LSMinimumSystemVersion in scripts/build.sh
    targets: [
        .executableTarget(
            name: "Unwine",
            path: "Sources/Unwine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
