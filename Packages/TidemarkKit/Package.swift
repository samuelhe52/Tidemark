// swift-tools-version: 6.4

import PackageDescription

/// Matches the app target's `SWIFT_APPROACHABLE_CONCURRENCY` and
/// `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`, so the same code behaves the same in both.
let sharedSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility")
]

/// The engine and the skins drive UI, so they default to the main actor like the app.
let mainActorSettings = sharedSettings + [.defaultIsolation(MainActor.self)]

/// The three concerns of Tidemark, kept apart by the compiler.
///
/// - `TidemarkEngine`: placement, docking, hover and pin state, interaction timing.
/// - `TidemarkAppearance`: skins (the orb, sprite pets) and their rendering.
/// - `TidemarkData`: quota and usage sources, normalization, freshness.
///
/// The app target is the only place that imports more than one of them.
let package = Package(
    name: "TidemarkKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TidemarkEngine", targets: ["TidemarkEngine"]),
        .library(name: "TidemarkAppearance", targets: ["TidemarkAppearance"]),
        .library(name: "TidemarkData", targets: ["TidemarkData"])
    ],
    targets: [
        .target(name: "TidemarkEngine", swiftSettings: mainActorSettings),
        .target(name: "TidemarkAppearance", swiftSettings: mainActorSettings),
        // Data reads files and calls the network, so it stays nonisolated by default.
        .target(name: "TidemarkData", swiftSettings: sharedSettings)
    ],
    swiftLanguageModes: [.v6]
)
