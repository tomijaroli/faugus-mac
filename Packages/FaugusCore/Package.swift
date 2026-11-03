// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaugusCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FaugusCore", targets: ["FaugusCore"])
    ],
    targets: [
        .target(
            name: "VorbisDecoder",
            path: "Sources/VorbisDecoder",
            sources: ["VorbisDecoder.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .unsafeFlags(["-Wno-tautological-compare"]),
            ]
        ),
        .target(name: "FaugusCore", dependencies: ["VorbisDecoder"]),
        .testTarget(
            name: "FaugusCoreTests",
            dependencies: ["FaugusCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
