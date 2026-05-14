// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexAccountTracker",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexAccountTracker", targets: ["CodexAccountTracker"])
    ],
    targets: [
        .executableTarget(
            name: "CodexAccountTracker",
            path: "Sources/CodexAccountTracker"
        )
    ]
)
