// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecoveryApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RecoveryApp", targets: ["RecoveryApp"])
    ],
    targets: [
        .executableTarget(
            name: "RecoveryApp",
            path: "Sources/RecoveryApp"
        ),
        .testTarget(
            name: "RecoveryAppTests",
            dependencies: ["RecoveryApp"],
            path: "Tests/RecoveryAppTests"
        )
    ]
)
