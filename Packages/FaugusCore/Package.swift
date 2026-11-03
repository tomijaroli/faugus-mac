// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaugusCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FaugusCore", targets: ["FaugusCore"])
    ],
    targets: [
        .target(name: "FaugusCore"),
        .testTarget(
            name: "FaugusCoreTests",
            dependencies: ["FaugusCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
