import Foundation

/// Builds the `Tests/Fixtures/CanaryApp` SwiftPM package with `swift
/// build`, producing a real IndexStore that the query tests can read.
///
/// We use `swift build` (instead of hand-rolling an .xcodeproj +
/// xcodebuild) because:
///   1. The query layer only needs *an* IndexStore — it doesn't care
///      which build system produced it. SwiftPM emits the same
///      indexstore-db format that Xcode does.
///   2. `swift build` on a minimal package emits the full relation
///      graph, including `baseOf` for protocol conformances, that
///      `findConformances` queries against.
///   3. No committed .pbxproj to maintain.
///
/// DerivedData-specific resolution (which IS Xcode-specific) is covered
/// separately by `DerivedDataLocatorTests` with pure FileManager
/// fixtures — no compiler invocation required.
enum FixtureBuilder {
    /// Absolute path to `Tests/Fixtures/CanaryApp`, resolved from this
    /// file's source location. Works in both `swift test` and Xcode.
    static let canaryAppDir: URL = {
        let thisFile = URL(fileURLWithPath: #filePath)
        // .../Tests/xcindexTests/Helpers/FixtureBuilder.swift
        //  -> .../Tests/Fixtures/CanaryApp
        return thisFile
            .deletingLastPathComponent() // Helpers
            .deletingLastPathComponent() // xcindexTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/CanaryApp")
    }()

    /// Absolute path to the canary Swift sources directory. Query tests
    /// use this to form expected `path` values without hard-coding.
    static var canarySourceDir: URL {
        canaryAppDir.appendingPathComponent("Sources/CanaryApp")
    }

    /// Build the canary fixture with `swift build` into a throwaway
    /// scratch dir, then return the resulting IndexStore path. Each
    /// call uses its own scratch root so parallel tests don't collide.
    static func buildCanaryIndex() throws -> BuiltIndex {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcindex-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )

        let swift = try resolveSwift()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: swift)
        proc.arguments = [
            "build",
            "--package-path", canaryAppDir.path,
            "--scratch-path", scratch.path,
            "-c", "debug",
        ]

        let stderr = Pipe()
        let stdout = Pipe()
        proc.standardError = stderr
        proc.standardOutput = stdout

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let err = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let out = String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw FixtureError.swiftBuildFailed(
                status: proc.terminationStatus,
                stderr: err,
                stdout: out
            )
        }

        // SwiftPM writes the index store to
        // <scratch>/<triple>/debug/index/store. The triple directory is
        // host-dependent (e.g. arm64-apple-macosx), so locate it by
        // scanning instead of hard-coding.
        let storePath = try locateIndexStore(in: scratch)

        return BuiltIndex(
            storePath: storePath,
            sourceDir: canarySourceDir.path,
            cleanupRoot: scratch
        )
    }

    private static func locateIndexStore(in scratch: URL) throws -> String {
        let fm = FileManager.default
        let triples = try fm.contentsOfDirectory(
            at: scratch,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        for triple in triples {
            let candidate = triple
                .appendingPathComponent("debug/index/store")
            if fm.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        throw FixtureError.indexStoreNotFound(scratch.path)
    }

    private static func resolveSwift() throws -> String {
        if let out = runCommand("/usr/bin/xcrun", args: ["--find", "swift"]) {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if FileManager.default.fileExists(atPath: "/usr/bin/swift") {
            return "/usr/bin/swift"
        }
        throw FixtureError.swiftNotFound
    }

    enum FixtureError: Error, CustomStringConvertible {
        case swiftNotFound
        case swiftBuildFailed(status: Int32, stderr: String, stdout: String)
        case indexStoreNotFound(String)

        var description: String {
            switch self {
            case .swiftNotFound:
                return "Could not locate swift via xcrun or /usr/bin."
            case .swiftBuildFailed(let status, let stderr, let stdout):
                return """
                swift build exited with status \(status).
                stderr: \(stderr)
                stdout: \(stdout)
                """
            case .indexStoreNotFound(let scratch):
                return "No index store found under \(scratch). SwiftPM did not emit an index."
            }
        }
    }
}

struct BuiltIndex {
    let storePath: String
    let sourceDir: String
    let cleanupRoot: URL

    func sourcePath(_ name: String) -> String {
        (sourceDir as NSString).appendingPathComponent(name)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: cleanupRoot)
    }
}

/// Tiny helper mirror of the one in Queries.swift. Duplicated deliberately
/// to keep the test target's dependency surface on the xcindex module
/// small — a free function in a different file.
private func runCommand(_ path: String, args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}
