// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenTeams",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenTeams", targets: ["TeamsChat"]),
        .library(name: "TeamsCore", targets: ["TeamsCore"]),
        .executable(name: "TeamsCredentialPrototype", targets: ["TeamsCredentialPrototype"]),
        .executable(name: "TeamsCredentialService", targets: ["TeamsCredentialService"]),
        .library(name: "TeamsCredentialBridge", targets: ["TeamsCredentialBridge"]),
        .executable(name: "TeamsCredentialBridgeProof", targets: ["TeamsCredentialBridgeProof"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup", exact: "2.9.6")
    ],
    targets: [
        .target(name: "TeamsCore", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")]),
        .executableTarget(
            name: "TeamsChat",
            dependencies: ["TeamsCore", "TeamsCredentialBridge", "TeamsCredentialPersistence"]
        ),
        .target(name: "TeamsCredentialIPC"),
        .target(name: "TeamsCredentialBridge", dependencies: ["TeamsCredentialIPC"]),
        .target(name: "TeamsCredentialPersistence", dependencies: ["TeamsCredentialBridge", "TeamsCore"]),
        .executableTarget(name: "TeamsCredentialPrototype"),
        .executableTarget(name: "TeamsCredentialService", dependencies: ["TeamsCredentialIPC"]),
        .executableTarget(name: "TeamsCredentialBridgeProof", dependencies: ["TeamsCredentialBridge", "TeamsCredentialIPC", "TeamsCredentialPersistence", "TeamsCore"]),
        .testTarget(name: "TeamsCoreTests", dependencies: ["TeamsCore"]),
        .testTarget(name: "TeamsChatTests", dependencies: ["TeamsChat", "TeamsCore", "TeamsCredentialPersistence"])
    ]
)
