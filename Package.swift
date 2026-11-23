// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DitheringEngine",
    platforms: [.iOS(.v18), .macOS(.v15), .visionOS("2.1")],
    products: [
        .library(name: "DitheringEngine", targets: ["DitheringEngine"])
    ],
    targets: [
        .target(
            name: "DitheringEngine",
            path: "DitheringEngine/DitheringEngine/Sources"
        ),
        .testTarget(
            name: "DitheringEngineTests",
            dependencies: ["DitheringEngine"],
            path: "DitheringEngine/DitheringEngineTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
