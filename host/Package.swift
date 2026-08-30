// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nazorid",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "nazorid",
            path: "Sources/nazorid"
        )
    ]
)
