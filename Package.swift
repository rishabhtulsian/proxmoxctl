// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "proxmoxctl",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "proxmoxctl", targets: ["proxmoxctl"]),
        .library(name: "ProxmoxCtlCore", targets: ["ProxmoxCtlCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2")
    ],
    targets: [
        .systemLibrary(name: "CEditLine"),
        .target(name: "ProxmoxCtlCore"),
        .executableTarget(
            name: "proxmoxctl",
            dependencies: [
                "CEditLine",
                "ProxmoxCtlCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "ProxmoxCtlCoreTests",
            dependencies: ["ProxmoxCtlCore"]
        )
    ]
)
