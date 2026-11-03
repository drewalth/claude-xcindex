import Foundation
import Testing
@testable import xcindex

// Fixtures use a coordinate tuple for readability; relax for this test file.
// swiftlint:disable large_tuple

/// Covers the three resolution branches of `DerivedDataLocator`:
///   1. Explicit `indexStorePath` wins and short-circuits everything else.
///   2. Scanning picks the most recently modified `<ProjectName>-*` entry.
///   3. Errors are raised when inputs or on-disk state are missing.
///
/// The scanning branch uses the `derivedDataBaseOverride` parameter to
/// point at a fixture directory under `$TMPDIR` rather than the user's
/// real `~/Library/Developer/Xcode/DerivedData`.
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
                derivedDataBaseOverride: dd
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
            derivedDataBaseOverride: dd
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
                derivedDataBaseOverride: dd
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
                derivedDataBaseOverride: dd
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
            derivedDataBaseOverride: dd
        )
        #expect(resolved.contains("MyApp-workspacehash"))
    }

    // MARK: - Worktrees / clones sharing a project name

    @Test("WorkspacePath match beats a newer same-named folder from another checkout")
    func workspacePathBeatsRecency() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let dd = try makeDerivedDataBase(base: base, projects: [
            ("MyApp-mine", daysAgo: 5, withIndexStore: true),
            ("MyApp-worktree", daysAgo: 0, withIndexStore: true)
        ])
        try writeInfoPlist(dd.appendingPathComponent("MyApp-mine"), workspacePath: "/src/app/MyApp.xcodeproj")
        try writeInfoPlist(dd.appendingPathComponent("MyApp-worktree"), workspacePath: "/src/app.wt/MyApp.xcodeproj")

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: "/src/app/MyApp.xcodeproj",
            indexStorePath: nil,
            derivedDataBaseOverride: dd
        )
        #expect(resolved.contains("MyApp-mine"))
    }

    @Test("a folder owned by another checkout is never used as a fallback")
    func foreignWorkspacePathRejected() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let dd = try makeDerivedDataBase(base: base, projects: [
            ("MyApp-worktree", daysAgo: 0, withIndexStore: true)
        ])
        try writeInfoPlist(dd.appendingPathComponent("MyApp-worktree"), workspacePath: "/src/app.wt/MyApp.xcodeproj")

        let thrown = #expect(throws: DerivedDataLocator.LocatorError.self) {
            _ = try DerivedDataLocator.indexStorePath(
                projectPath: "/src/app/MyApp.xcodeproj",
                indexStorePath: nil,
                derivedDataBaseOverride: dd
            )
        }
        assertLocator(thrown, is: .noDerivedData)
    }

    @Test("WorkspacePath comparison resolves symlinks")
    func workspacePathSymlinks() throws {
        // ~/dev symlinked to another volume is common; Xcode records the
        // real path, Claude may pass the link.
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try fm.createDirectory(at: real.appendingPathComponent("MyApp.xcodeproj"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let project = link.appendingPathComponent("MyApp.xcodeproj")

        let dd = try makeDerivedDataBase(base: base.appendingPathComponent("dd"), projects: [
            ("MyApp-mine", daysAgo: 0, withIndexStore: true)
        ])
        try writeInfoPlist(
            dd.appendingPathComponent("MyApp-mine"),
            workspacePath: real.appendingPathComponent("MyApp.xcodeproj").path
        )

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: project.path,
            indexStorePath: nil,
            derivedDataBaseOverride: dd
        )
        #expect(resolved.contains("MyApp-mine"))
    }

    // MARK: - Directory projectPath

    @Test("a directory projectPath resolves to the project bundle inside it")
    func directoryResolvesToProject() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("my-app")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("MyApp.xcodeproj/project.xcworkspace"),
            withIntermediateDirectories: true
        )

        let dd = try makeDerivedDataBase(base: base.appendingPathComponent("dd"), projects: [
            ("MyApp-hash", daysAgo: 0, withIndexStore: true)
        ])

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: repo.path,
            indexStorePath: nil,
            derivedDataBaseOverride: dd
        )
        #expect(resolved.contains("MyApp-hash"))
    }

    @Test("a directory projectPath prefers .xcworkspace over .xcodeproj")
    func directoryPrefersWorkspace() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo")
        let fm = FileManager.default
        try fm.createDirectory(at: repo.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("Suite.xcworkspace"), withIntermediateDirectories: true)

        let dd = try makeDerivedDataBase(base: base.appendingPathComponent("dd"), projects: [
            ("App-hash", daysAgo: 0, withIndexStore: true),
            ("Suite-hash", daysAgo: 1, withIndexStore: true)
        ])

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: repo.path,
            indexStorePath: nil,
            derivedDataBaseOverride: dd
        )
        #expect(resolved.contains("Suite-hash"))
    }

    @Test("a directory with no project bundle keeps its own name (SwiftPM package)")
    func directoryWithoutProjectUsesBasename() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let pkg = base.appendingPathComponent("Pkg")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)

        let dd = try makeDerivedDataBase(base: base.appendingPathComponent("dd"), projects: [
            ("Pkg-hash", daysAgo: 0, withIndexStore: true)
        ])

        let resolved = try DerivedDataLocator.indexStorePath(
            projectPath: pkg.path,
            indexStorePath: nil,
            derivedDataBaseOverride: dd
        )
        #expect(resolved.contains("Pkg-hash"))
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
    let fm = FileManager.default
    for (name, daysAgo, withIndexStore) in projects {
        let folder = base.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if withIndexStore {
            let ds = folder.appendingPathComponent("Index.noindex/DataStore")
            try fm.createDirectory(at: ds, withIntermediateDirectories: true)
        }
        let mtime = Date(timeIntervalSinceNow: -Double(daysAgo) * 86400)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: folder.path)
    }
    return base
}

/// Xcode records the owning project in `<DerivedData folder>/info.plist`.
private func writeInfoPlist(_ folder: URL, workspacePath: String) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: ["WorkspacePath": workspacePath],
        format: .xml,
        options: 0
    )
    try data.write(to: folder.appendingPathComponent("info.plist"))
}

// swiftlint:enable large_tuple
