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
        try buildSPMIndex(
            packagePath: canaryAppDir,
            sourceDir: canarySourceDir,
            reuseScratch: nil
        )
    }

    /// Build an arbitrary SPM package and return the resulting
    /// IndexStore. Used by external-fixture tests (TCA, swift-log) that
    /// share canary's build pipeline but target a different package root.
    ///
    /// - Parameters:
    ///   - packagePath: Root of the SwiftPM package (dir containing
    ///     `Package.swift`).
    ///   - sourceDir: Directory used by tests to anchor `path_basename`
    ///     comparisons. Typically `packagePath/Sources/<lib>`.
    ///   - reuseScratch: Reuse this scratch root between test runs
    ///     (persists the SwiftPM cache across invocations). Pass `nil`
    ///     for a fresh throwaway dir per call.
    static func buildSPMIndex(
        packagePath: URL,
        sourceDir: URL,
        reuseScratch: URL?
    ) throws -> BuiltIndex {
        let scratch: URL
        if let reuseScratch {
            try FileManager.default.createDirectory(
                at: reuseScratch, withIntermediateDirectories: true
            )
            scratch = reuseScratch
        } else {
            scratch = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("xcindex-fixture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: scratch, withIntermediateDirectories: true
            )
        }

        let swift = try resolveSwift()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: swift)
        proc.arguments = [
            "build",
            "--package-path", packagePath.path,
            "--scratch-path", scratch.path,
            "-c", "debug",
        ]

        // Drain stdout/stderr concurrently. Without this, big builds
        // (TCA with macro deps) overflow the 16KB pipe buffer and
        // swift-build blocks on stdout write, deadlocking
        // waitUntilExit(). Canary is small enough to fit inside one
        // buffer, which is why this bug only surfaces on heavy builds.
        let stderr = Pipe()
        let stdout = Pipe()
        proc.standardError = stderr
        proc.standardOutput = stdout

        let stderrBuffer = DrainingBuffer()
        let stdoutBuffer = DrainingBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(data)
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.append(data)
            }
        }

        try proc.run()
        proc.waitUntilExit()

        // Detach the handlers so they don't fire against a closed FD.
        stderr.fileHandleForReading.readabilityHandler = nil
        stdout.fileHandleForReading.readabilityHandler = nil

        guard proc.terminationStatus == 0 else {
            throw FixtureError.swiftBuildFailed(
                status: proc.terminationStatus,
                stderr: stderrBuffer.string(),
                stdout: stdoutBuffer.string()
            )
        }

        // SwiftPM writes the index store to
        // <scratch>/<triple>/debug/index/store. The triple directory is
        // host-dependent (e.g. arm64-apple-macosx), so locate it by
        // scanning instead of hard-coding.
        let storePath = try locateIndexStore(in: scratch)

        // reuseScratch = nil: scratch is throwaway, cleanupRoot should
        // remove it. reuseScratch = non-nil: caller manages lifetime,
        // don't blow away cached builds between runs.
        let cleanupRoot = reuseScratch == nil ? scratch : URL(fileURLWithPath: "/dev/null")

        return BuiltIndex(
            storePath: storePath,
            sourceDir: sourceDir.path,
            cleanupRoot: cleanupRoot
        )
    }

    // MARK: - External fixtures (TCA, swift-log, …)

    /// Build an IndexStore for a pre-cloned external SwiftPM fixture.
    /// Skips gracefully if the checkout isn't present so local
    /// `swift test` runs don't require every developer to fetch the
    /// fixture. CI spins up the checkout explicitly via
    /// `scripts/fetch-fixture.sh <name>`.
    ///
    /// Discovery priority:
    ///   1. `<NAME>_FIXTURE_DIR` env var (uppercased, e.g. `TCA_FIXTURE_DIR`).
    ///   2. Newest directory under
    ///      `~/Library/Caches/claude-xcindex/<name>-*` containing
    ///      a `Package.swift`.
    ///
    /// Returns `nil` when no checkout resolves.
    static func buildExternalIndexIfAvailable(name: String) throws -> BuiltIndex? {
        guard let checkoutPath = locateExternalCheckout(name: name) else { return nil }

        let scratch = externalScratchRoot(name: name)
        let sourceDir = checkoutPath.appendingPathComponent("Sources")

        return try buildSPMIndex(
            packagePath: checkoutPath,
            sourceDir: sourceDir,
            reuseScratch: scratch
        )
    }

    static func locateExternalCheckout(name: String) -> URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        let envKey = "\(name.uppercased().replacingOccurrences(of: "-", with: "_"))_FIXTURE_DIR"
        if let override = env[envKey], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }

        let home = fm.homeDirectoryForCurrentUser
        let cacheDir = home.appendingPathComponent("Library/Caches/claude-xcindex")
        guard let entries = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        let prefix = "\(name)-"
        for entry in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard entry.lastPathComponent.hasPrefix(prefix) else { continue }
            let pkg = entry.appendingPathComponent("Package.swift")
            if fm.fileExists(atPath: pkg.path) {
                return entry
            }
        }
        return nil
    }

    /// Persistent scratch for incremental builds — one stable dir per
    /// fixture name so different pinned SHAs share cache state but
    /// fixtures don't step on each other.
    private static func externalScratchRoot(name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcindex-\(name)-build")
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

/// Thread-safe Data accumulator used by the pipe-draining handlers.
/// Pipe readability callbacks fire on an arbitrary Dispatch queue, so
/// a plain `var data = Data()` is a data race waiting to happen.
private final class DrainingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
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
