// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Snappy",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Snappy"
        ),
        .testTarget(
            name: "SnappyTests",
            dependencies: ["Snappy"]
        ),
    ]
)
