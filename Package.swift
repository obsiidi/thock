// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "thock",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "thock",
            path: "Sources/thock"
        )
    ]
)
