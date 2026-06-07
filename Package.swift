// swift-tools-version: 6.0
// This is a Skip (https://skip.tools) package for the Maxi80 radio player.
import PackageDescription

let package = Package(
    name: "Maxi80",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "Maxi80", type: .dynamic, targets: ["Maxi80"]),
        .library(name: "Maxi80Model", type: .dynamic, targets: ["Maxi80Model"]),
        .library(name: "Maxi80Services", type: .dynamic, targets: ["Maxi80Services"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-fuse-ui.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-fuse.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-foundation.git", from: "1.0.0"),
        .package(url: "https://github.com/typelift/SwiftCheck.git", from: "0.12.0"),
    ],
    targets: [
        .target(name: "Maxi80Model", dependencies: [
            .product(name: "SkipFuse", package: "skip-fuse"),
        ], plugins: [.plugin(name: "skipstone", package: "skip")]),

        .testTarget(name: "Maxi80ModelTests", dependencies: [
            "Maxi80Model",
            "SwiftCheck",
            .product(name: "SkipTest", package: "skip"),
        ], plugins: [.plugin(name: "skipstone", package: "skip")]),

        .target(name: "Maxi80", dependencies: [
            "Maxi80Model",
            "Maxi80Services",
            .product(name: "SkipFuseUI", package: "skip-fuse-ui"),
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),

        .testTarget(name: "Maxi80Tests", dependencies: [
            "Maxi80",
            "SwiftCheck",
            .product(name: "SkipTest", package: "skip"),
        ], plugins: [.plugin(name: "skipstone", package: "skip")]),

        .target(name: "Maxi80Services", dependencies: [
            .product(name: "SkipFoundation", package: "skip-foundation"),
        ], plugins: [.plugin(name: "skipstone", package: "skip")]),

        .testTarget(name: "Maxi80ServicesTests", dependencies: [
            "Maxi80Services",
            .product(name: "SkipTest", package: "skip"),
        ], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)

// SKIP_BRIDGE conditional block:
// When building for Android with bridging enabled (SKIP_BRIDGE=1),
// add SkipBridge dependency to Maxi80Services for JNI bridging support.
if Context.environment["SKIP_BRIDGE"] ?? "0" != "0" {
    package.dependencies += [
        .package(url: "https://source.skip.tools/skip-bridge.git", "0.0.0"..<"2.0.0")
    ]
    package.targets.forEach({ target in
        if target.name == "Maxi80Services" {
            target.dependencies += [.product(name: "SkipBridge", package: "skip-bridge")]
        }
    })
}
