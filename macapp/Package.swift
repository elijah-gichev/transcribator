// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Transcribator",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Transcribator",
            path: "Sources/Transcribator"
        )
    ]
)
