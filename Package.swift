// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "thock",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Tiny C shim: acquire/release atomics for the lock-free event ring.
        .target(
            name: "CAtomics",
            path: "Sources/CAtomics"
        ),
        .executableTarget(
            name: "thock",
            dependencies: ["CAtomics"],
            path: "Sources/thock"
        )
    ]
)
