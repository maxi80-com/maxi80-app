// swift-tools-version: 6.0
// This is a Skip (https://skip.tools) package for the Maxi80 radio player.
import PackageDescription

// The SwiftUI `#Preview` macro is expanded by the `PreviewsMacros` compiler
// plugin, which ships only with Xcode's toolchain — not the bare toolchain used
// by `swift build`. Detect an Xcode-driven build (Xcode sets its bundle id in
// the manifest environment) so we can gate preview code behind ENABLE_PREVIEWS
// and keep command-line / Android builds compiling.
let isXcodeBuild = Context.environment["__CFBundleIdentifier"] == "com.apple.dt.Xcode"
let previewSettings: [SwiftSetting] = isXcodeBuild ? [.define("ENABLE_PREVIEWS")] : []

// SwiftCheck (property-based testing) imports `Darwin`, which does not exist on
// the Android SDK, so it fails to compile whenever `swift build --build-tests`
// pulls it into an Android build. The Android/bridging build is the one that
// sets SKIP_BRIDGE=1, so on that build we drop the SwiftCheck dependency and
// exclude the property-test files (they run on Apple platforms only).
let isAndroidBuild = Context.environment["SKIP_BRIDGE"] ?? "0" != "0"
let swiftCheckDependencies: [PackageDescription.Package.Dependency] =
  isAndroidBuild
  ? [] : [.package(url: "https://github.com/typelift/SwiftCheck.git", from: "0.12.0")]
let swiftCheckTargetDependencies: [Target.Dependency] = isAndroidBuild ? [] : ["SwiftCheck"]
let modelPropertyTestExclusions =
  isAndroidBuild
  ? ["MetadataParserPropertyTests.swift", "APIClientPropertyTests.swift"] : []
let appPropertyTestExclusions =
  isAndroidBuild
  ? [
    "StationFallbackPropertyTests.swift", "ReconnectionPropertyTests.swift",
    "HistoryPropertyTests.swift", "ViewModelPropertyTests.swift", "ShareTextPropertyTests.swift",
  ]
  : []

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
  ] + swiftCheckDependencies,
  targets: [
    .target(
      name: "Maxi80Model",
      dependencies: [
        .product(name: "SkipFuse", package: "skip-fuse")
      ], plugins: [.plugin(name: "skipstone", package: "skip")]),

    .testTarget(
      name: "Maxi80ModelTests",
      dependencies: [
        "Maxi80Model",
        .product(name: "SkipTest", package: "skip"),
      ] + swiftCheckTargetDependencies, exclude: modelPropertyTestExclusions,
      plugins: [.plugin(name: "skipstone", package: "skip")]),

    .target(
      name: "Maxi80",
      dependencies: [
        "Maxi80Model",
        "Maxi80Services",
        .product(name: "SkipFuseUI", package: "skip-fuse-ui"),
      ], resources: [.process("Resources")], swiftSettings: previewSettings,
      plugins: [.plugin(name: "skipstone", package: "skip")]),

    .testTarget(
      name: "Maxi80Tests",
      dependencies: [
        "Maxi80",
        .product(name: "SkipTest", package: "skip"),
      ] + swiftCheckTargetDependencies, exclude: appPropertyTestExclusions,
      plugins: [.plugin(name: "skipstone", package: "skip")]),

    .target(
      name: "Maxi80Services",
      dependencies: [
        .product(name: "SkipFoundation", package: "skip-foundation")
      ], plugins: [.plugin(name: "skipstone", package: "skip")]),

    .testTarget(
      name: "Maxi80ServicesTests",
      dependencies: [
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
