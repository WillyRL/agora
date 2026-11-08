// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Agora",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Agora", targets: ["Agora"]),
        .library(name: "AgoraCore", targets: ["AgoraCore"]),
    ],
    targets: [
        .target(name: "AgoraCore"),
        .executableTarget(name: "Agora", dependencies: ["AgoraCore"]),
        .executableTarget(name: "agora-record", dependencies: ["AgoraCore"]),
        .testTarget(
            name: "AgoraCoreTests",
            dependencies: ["AgoraCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
