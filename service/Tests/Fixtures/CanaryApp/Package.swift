// swift-tools-version: 5.9
// Minimal SwiftPM package used as a build-time fixture by
// `IndexQuerierTests`. `swift build` on this package produces a full
// IndexStore under `.build/<triple>/debug/index/store` — including
// protocol conformance (`baseOf`) relations — which is what the query
// tests assert against.
//
// Pure-Swift, no external dependencies, no executable. Do not import
// this from the main xcindex package.
import PackageDescription

let package = Package(
    name: "CanaryApp",
    products: [
        .library(name: "CanaryApp", targets: ["CanaryApp"]),
    ],
    targets: [
        .target(
            name: "CanaryApp",
            path: "Sources/CanaryApp"
        ),
    ]
)
