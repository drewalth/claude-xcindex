// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "xcindex",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Follow sourcekit-lsp's main to stay wire-compatible with the
        // upstream indexstore-db pin. Previously pinned to a specific
        // revision; the pin conflicted with sourcekit-lsp's own pin.
        .package(url: "https://github.com/swiftlang/indexstore-db.git", branch: "main"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        // swift-tools-protocols is Apple's minimal Swift package that
        // exposes the typed LanguageServerProtocol messages plus a
        // JSONRPCConnection transport. We spawn sourcekit-lsp as a
        // subprocess and wire up stdio via this library. Eng Review
        // Decision 1. Using this package directly (rather than the
        // whole sourcekit-lsp bundle) keeps the binary small — we skip
        // the in-process LSP service, Clang/Swift language services,
        // and BuildServerIntegration that we don't need.
        .package(url: "https://github.com/swiftlang/swift-tools-protocols.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "xcindex",
            dependencies: [
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "LanguageServerProtocol", package: "swift-tools-protocols"),
                .product(name: "LanguageServerProtocolTransport", package: "swift-tools-protocols"),
            ],
            path: "Sources/xcindex"
        ),
        .testTarget(
            name: "xcindexTests",
            dependencies: ["xcindex"],
            path: "Tests/xcindexTests"
        ),
    ]
)
