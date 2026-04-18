// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "xcindex",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/indexstore-db.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "xcindex",
            dependencies: [
                .product(name: "IndexStoreDB", package: "indexstore-db"),
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
