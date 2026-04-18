// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "xcindex",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "4ee7a49edc48e94361c3477623deeffb25dbed0d"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "xcindex",
            dependencies: [
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                .product(name: "MCP", package: "swift-sdk"),
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
