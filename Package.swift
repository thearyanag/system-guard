// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SystemGuard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SystemGuard", targets: ["SystemGuard"])
    ],
    targets: [
        .executableTarget(
            name: "SystemGuard"
        )
    ]
)
