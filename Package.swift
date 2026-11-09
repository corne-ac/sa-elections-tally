// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tally",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tally",
            path: "Sources/Tally"
        )
    ]
)
