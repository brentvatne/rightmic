// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RightMic",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "RightMicCore",
            path: "Sources/RightMicCore"
        ),
        .executableTarget(
            name: "RightMic",
            dependencies: ["RightMicCore"],
            path: "Sources/RightMic",
            exclude: ["Info.plist", "RightMic.entitlements"],
            resources: [
                .process("../Resources")
            ]
        ),
        .testTarget(
            name: "RightMicTests",
            dependencies: ["RightMicCore"],
            path: "Tests/RightMicTests"
        )
    ]
)
