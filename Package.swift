// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VirtualBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VirtualBar",
            path: "Sources/VirtualBar",
            exclude: ["Info.plist"]
        )
    ]
)
