import Foundation
import Testing
@testable import xcindex

// Fixtures use a coordinate tuple for readability; relax for this test file.
// swiftlint:disable large_tuple

/// Covers the resolution branches of `DerivedDataLocator`:
///   1. Explicit `indexStorePath` wins and short-circuits everything else.
///   2. Scanning picks the most recently modified `<ProjectName>-*` entry.
///   3. A relative custom `IDECustomDerivedDataLocation` resolves against the
///      project's directory and matches unhashed `<ProjectName>` containers.
///   4. `info.plist`'s `WorkspacePath` provenance beats mtime; a candidate
///      set of only mismatching workspaces is refused, never silently used.
///   5. Errors are raised when inputs or on-disk state are missing.
///
/// The scanning branch uses the `derivedDataBaseOverride` parameter to
/// point at a fixture directory under `$TMPDIR` rather than the user's
/// real `~/Library/Developer/Xcode/DerivedData`, and `customLocation` to
/// avoid reading the developer's real Xcode defaults.
@Suite("DerivedDataLocator")
struct DerivedDataLocatorTests {
    // MARK: - Explicit path

    @Test("explicit indexStorePath short-circuits scanning")
    func explicitPathWins() throws {
        let path = try DerivedDataLocator.indexStorePath(
            projectPath: "/ignored/Foo.xcodeproj",
            indexStorePath: "/my/explicit/DataStore"
        )
        #expect(path == "/my/explicit/DataStore")
    }

    @Test("empty indexStorePath falls through to scanning")
    func emptyExplicitPathFallsThrough() throws {
        // An empty string is treated as "not provided" — ensures callers
        // that pass "" get the same behavior as callers that pass nil.
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let dd = try makeDerivedDataBase(base: base, projects: [
            ("Missing-abc123", daysAgo: 0, withIndexStore: true)
        ])

        #expect(throws: DerivedDataLocator.LocatorError.self) {
            _ = try DerivedDataLocator.indexStorePath(
                projectPath: "",
                indexStorePath: "",
                derivedDataBaseOverride: dd,
                customLocation: .none
            )
        }
    }

    // MARK: - Missing inputs

    @Test("missing both projectPath and indexStorePath throws noProjectPath")
    func bothMissing() throws {
        let thrown = #expect(throws: DerivedDataLocator.LocatorError.self) {
            _ = try DerivedDataLocator.indexStorePath(
                projectPath: nil,
                indexStorePath: nil
            )
        }
        assertLocator(thrown, is: .noProjectPath)
    }

    // MARK: - Scanning

    @Test("scanning picks the most recently modified matching DerivedData entry")
    func scanPicksMostRecent() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let dd = try makeDerivedDataBase(base: base, projects: [
            ("MyApp-oldhash", daysAgo: 5, withIndexStore: true),
            ("MyApp-newerhash", daysAgo: 1, withIndexStore: true),
            ("OtherApp-unrelated", daysAgo: 0, withIndexStore: true)
        ])

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: "/Projects/MyApp.xcodeproj",
            indexStorePath: nil,
            derivedDataBaseOverride: dd,
            customLocation: .none
        )

        #expect(resolved.contains("MyApp-newerhash"))
        #expect(resolved.hasSuffix("Index.noindex/DataStore"))
    }

    @Test("scanning throws noDerivedData when no project-named folder exists")
    func scanNoMatches() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let dd = try makeDerivedDataBase(base: base, projects: [
            ("UnrelatedProject-abc", daysAgo: 0, withIndexStore: true)
        ])

        let thrown = #expect(throws: DerivedDataLocator.LocatorError.self) {
            _ = try DerivedDataLocator.indexStorePath(
                projectPath: "/Projects/MyApp.xcodeproj",
                indexStorePath: nil,
                derivedDataBaseOverride: dd,
                customLocation: .none
            )
        }
        assertLocator(thrown, is: .noDerivedData)
    }

    @Test("scanning throws noIndexStore when DerivedData dir has no Index.noindex")
    func scanFolderMissingIndexStore() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let dd = try makeDerivedDataBase(base: base, projects: [
            ("MyApp-abc", daysAgo: 0, withIndexStore: false)
        ])

        let thrown = #expect(throws: DerivedDataLocator.LocatorError.self) {
            _ = try DerivedDataLocator.indexStorePath(
                projectPath: "/Projects/MyApp.xcodeproj",
                indexStorePath: nil,
                derivedDataBaseOverride: dd,
                customLocation: .none
            )
        }
        assertLocator(thrown, is: .noIndexStore)
    }

    @Test("workspace paths have the same project-name derivation as xcodeproj")
    func workspaceNameDerivation() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let dd = try makeDerivedDataBase(base: base, projects: [
            ("MyApp-workspacehash", daysAgo: 0, withIndexStore: true)
        ])

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: "/Projects/MyApp.xcworkspace",
            indexStorePath: nil,
            derivedDataBaseOverride: dd,
            customLocation: .none
        )
        #expect(resolved.contains("MyApp-workspacehash"))
    }

    // MARK: - Custom location

    @Test("relative custom location resolves against the project dir and matches unhashed container names")
    func relativeCustomLocationResolvesAgainstProjectDir() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let projectDir = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let workspace = projectDir.appendingPathComponent("MyApp.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let container = projectDir.appendingPathComponent("DerivedData/MyApp")
        try makeContainer(
            container,
            withIndexStore: true,
            workspacePath: workspace.path
        )

        let missingOverride = root.appendingPathComponent("does-not-exist")

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: workspace.path,
            indexStorePath: nil,
            derivedDataBaseOverride: missingOverride,
            customLocation: .value("DerivedData")
        )

        // FileManager reports the DataStore path with /var resolved to
        // /private/var, but URL.standardizedFileURL / resolvingSymlinksInPath
        // deliberately do not resolve /var, /tmp, /etc symlinks — so an
        // exact-path comparison built from `container` directly is
        // environment-fragile. hasSuffix matches this file's existing
        // convention for the same reason (see scanPicksMostRecent).
        #expect(resolved.hasSuffix("/proj/DerivedData/MyApp/Index.noindex/DataStore"))
    }

    @Test("absolute custom location is scanned alongside the default root")
    func absoluteCustomLocationScannedAlongsideDefaultRoot() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let customBase = root.appendingPathComponent("customDD/MyApp-abc123")
        try makeContainer(customBase, withIndexStore: true, workspacePath: nil)

        let emptyDefaultRoot = root.appendingPathComponent("empty-default")

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: "/Projects/MyApp.xcodeproj",
            indexStorePath: nil,
            derivedDataBaseOverride: emptyDefaultRoot,
            customLocation: .value(customBase.deletingLastPathComponent().path)
        )

        #expect(resolved.contains("MyApp-abc123"))
    }

    @Test("a provenance-verified candidate beats a newer candidate from another workspace")
    func provenanceVerifiedCandidateBeatsNewerMismatch() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let realWorkspace = root.appendingPathComponent("MyApp.xcworkspace")
        try FileManager.default.createDirectory(at: realWorkspace, withIntermediateDirectories: true)

        let dd = root.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true)

        let mine = dd.appendingPathComponent("MyApp-minehash")
        try makeContainer(mine, withIndexStore: true, workspacePath: realWorkspace.path, daysAgo: 5)

        let sibling = dd.appendingPathComponent("MyApp-siblinghash")
        try makeContainer(
            sibling,
            withIndexStore: true,
            workspacePath: root.appendingPathComponent("OtherCheckout/MyApp.xcworkspace").path,
            daysAgo: 0
        )

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: realWorkspace.path,
            indexStorePath: nil,
            derivedDataBaseOverride: dd,
            customLocation: .none
        )

        #expect(resolved.contains("MyApp-minehash"))
    }

    @Test("bare .xcodeproj builds record the bundle-internal workspace and still verify")
    func bareXcodeprojRecordsBundleInternalWorkspace() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let projectDir = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let xcodeproj = projectDir.appendingPathComponent("MyApp.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)

        let dd = root.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true)

        let verified = dd.appendingPathComponent("MyApp-verifiedhash")
        try makeContainer(
            verified,
            withIndexStore: true,
            workspacePath: xcodeproj.appendingPathComponent("project.xcworkspace").path,
            daysAgo: 5
        )

        let mismatch = dd.appendingPathComponent("MyApp-mismatchhash")
        try makeContainer(
            mismatch,
            withIndexStore: true,
            workspacePath: "/elsewhere/MyApp.xcodeproj/project.xcworkspace",
            daysAgo: 0
        )

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: xcodeproj.path,
            indexStorePath: nil,
            derivedDataBaseOverride: dd,
            customLocation: .none
        )

        #expect(resolved.contains("MyApp-verifiedhash"))
    }

    @Test("candidates that all verify against other workspaces are refused, not silently used")
    func candidatesAllMismatchedAreRefused() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let dd = root.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true)

        let mismatch = dd.appendingPathComponent("MyApp-mismatchhash")
        try makeContainer(
            mismatch,
            withIndexStore: true,
            workspacePath: "/elsewhere/MyApp.xcworkspace"
        )

        let thrown = #expect(throws: DerivedDataLocator.LocatorError.self) {
            _ = try DerivedDataLocator.indexStorePath(
                projectPath: "/Projects/MyApp.xcworkspace",
                indexStorePath: nil,
                derivedDataBaseOverride: dd,
                customLocation: .none
            )
        }
        assertLocator(thrown, is: .noMatchingWorkspace)
    }

    @Test("candidates without an info.plist keep the legacy newest-wins behavior")
    func candidatesWithoutPlistKeepLegacyNewestWins() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let dd = root.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true)

        let old = dd.appendingPathComponent("MyApp-old")
        try makeContainer(old, withIndexStore: true, workspacePath: nil, daysAgo: 5)

        let newer = dd.appendingPathComponent("MyApp-new")
        try makeContainer(newer, withIndexStore: true, workspacePath: nil, daysAgo: 1)

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: "/Projects/MyApp.xcodeproj",
            indexStorePath: nil,
            derivedDataBaseOverride: dd,
            customLocation: .none
        )

        #expect(resolved.contains("MyApp-new"))
    }
}

// MARK: - Fixture helpers

private func makeTempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xcindex-dd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private enum LocatorCase {
    case noProjectPath
    case invalidProjectPath
    case noDerivedData
    case noMatchingWorkspace
    case noIndexStore
}

/// Typed check that an expected `LocatorError` case was thrown. Avoids
/// inlining an `if case` ladder at every call site and keeps assertion
/// messages informative when the wrong case is thrown.
private func assertLocator(
    _ thrown: (any Error)?,
    is expected: LocatorCase,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let error = thrown as? DerivedDataLocator.LocatorError else {
        Issue.record(
            "expected LocatorError, got \(String(describing: thrown))",
            sourceLocation: sourceLocation
        )
        return
    }
    let actual: LocatorCase = switch error {
    case .noProjectPath: .noProjectPath
    case .invalidProjectPath: .invalidProjectPath
    case .noDerivedData: .noDerivedData
    case .noMatchingWorkspace: .noMatchingWorkspace
    case .noIndexStore: .noIndexStore
    }
    #expect(actual == expected, "expected .\(expected), got .\(actual)", sourceLocation: sourceLocation)
}

/// Build a fake DerivedData tree under `base`. Each tuple becomes a
/// `<name>/Index.noindex/DataStore/` (optionally) with a modification
/// date set `daysAgo` days in the past.
private func makeDerivedDataBase(
    base: URL,
    projects: [(String, daysAgo: Int, withIndexStore: Bool)]
) throws -> URL {
    for (name, daysAgo, withIndexStore) in projects {
        try makeContainer(
            base.appendingPathComponent(name),
            withIndexStore: withIndexStore,
            workspacePath: nil,
            daysAgo: daysAgo
        )
    }
    return base
}

/// Create a DerivedData container dir with optional DataStore and optional
/// info.plist carrying WorkspacePath. mtime is set LAST (writing the plist
/// would otherwise bump it).
private func makeContainer(
    _ url: URL,
    withIndexStore: Bool,
    workspacePath: String?,
    daysAgo: Int = 0
) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: url, withIntermediateDirectories: true)

    if withIndexStore {
        let ds = url.appendingPathComponent("Index.noindex/DataStore")
        try fm.createDirectory(at: ds, withIntermediateDirectories: true)
    }

    if let workspacePath {
        let plist = ["WorkspacePath": workspacePath]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url.appendingPathComponent("info.plist"))
    }

    let mtime = Date(timeIntervalSinceNow: -Double(daysAgo) * 86400)
    try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
}

// swiftlint:enable large_tuple
