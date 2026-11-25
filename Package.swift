// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bonkeys",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "BonkeysCore"),
        .executableTarget(
            name: "Bonkeys",
            dependencies: ["BonkeysCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "BonkeysCoreTests", dependencies: ["BonkeysCore"]),
    ]
)
