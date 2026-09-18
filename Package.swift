// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecoveryApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RecoveryApp", targets: ["RecoveryApp"]),
        .executable(name: "recoveryapp-cli", targets: ["recoveryapp-cli"])
    ],
    targets: [
        .target(
            name: "RecoveryCore",
            path: "Sources/RecoveryCore"
        ),
        .executableTarget(
            name: "RecoveryApp",
            dependencies: ["RecoveryCore"],
            path: "Sources/RecoveryApp"
        ),
        .executableTarget(
            name: "recoveryapp-cli",
            dependencies: ["RecoveryCore"],
            path: "Sources/recoveryapp-cli"
        ),
        .testTarget(
            name: "RecoveryAppTests",
            dependencies: ["RecoveryApp"],
            path: "Tests/RecoveryAppTests"
        )
    ]
)
