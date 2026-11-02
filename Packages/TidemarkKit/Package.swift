// swift-tools-version: 6.0

import PackageDescription

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
        .target(name: "TidemarkEngine"),
        .target(name: "TidemarkAppearance"),
        .target(name: "TidemarkData")
    ]
)
