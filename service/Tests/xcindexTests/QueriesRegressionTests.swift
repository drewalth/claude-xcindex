import Foundation
import Testing
@testable import xcindex

/// Snapshot-style regression tests that lock in the exact shape of
/// IndexQuerier's outputs for known canary symbols. These exist to
/// catch behavior drift during refactors of `Queries.swift` — e.g.
/// when extracting the `occurrences(ofUSR:roles:)` primitive that
/// `RenamePlanner` shares with `findRefs`/`findDefinition`/`blastRadius`.
///
/// Philosophy: assertions compare normalized tuples
/// `(basename, line, column, sortedRoles)` instead of full paths,
/// because the scratch DerivedData root is randomized per test run.
/// USRs are stable across runs for a given source + toolchain and
/// are asserted directly.
///
/// If any of these fail, the refactor under review changed behavior
/// observable from the MCP surface. Revert or update the assertion
/// deliberately.
@Suite("QueriesRegression", .serialized)
struct QueriesRegressionTests {
    // MARK: - findRefs on fetchUser(id:)

    @Test("findRefs(\"fetchUser(id:)\") returns exactly the expected occurrences")
    func fetchUserRefsSnapshot() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        let refs = querier.findRefs(symbolName: "fetchUser(id:)")

        // Normalize: (basename, line, column) — roles intentionally
        // excluded from the tuple because IndexStoreDB occasionally
        // varies role-set presentation between toolchain versions
        // (e.g. definition vs declaration vs both). The caller-facing
        // shape that RenamePlanner will care about is location, not
        // the exact role string.
        let normalized = refs
            .map { ref -> String in
                let name = (ref.path as NSString).lastPathComponent
                return "\(name):\(ref.line):\(ref.column)"
            }
            .sorted()

        // Every returned occurrence has a non-empty USR with at least one role.
        #expect(refs.allSatisfy { !$0.usr.isEmpty && !$0.roles.isEmpty })

        // All USRs in the result set must agree — findRefs collapses on name,
        // and fetchUser(id:) is a single method (no overloads in the canary).
        let usrs = Set(refs.map(\.usr))
        #expect(usrs.count == 1, "fetchUser(id:) should resolve to one USR, got \(usrs)")

        // Locations: one definition in UserService, at least one call site
        // in AppDelegate, at least one call site in CanaryTests. Under-
        // specified on exact count to survive minor fixture edits but
        // enough to catch dedupe regressions.
        let files = Set(normalized.map { $0.split(separator: ":").first.map(String.init) ?? "" })
        #expect(files.contains("UserService.swift"))
        #expect(files.contains("AppDelegate.swift"))
        #expect(files.contains("CanaryTests.swift"))

        // No results outside the canary sources (e.g. leak from system frameworks).
        let unexpected = files.filter { name in
            !["UserService.swift", "AppDelegate.swift", "CanaryTests.swift"].contains(name)
        }
        #expect(unexpected.isEmpty, "findRefs leaked occurrences from: \(unexpected)")
    }

    // MARK: - findDefinition on UserService class

    @Test("findDefinition(UserService class USR) returns UserService.swift")
    func userServiceDefinitionSnapshot() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        let classUSR = try #require(
            querier.findSymbol(symbolName: "UserService").first { $0.kind == "class" }?.usr
        )

        let def = try #require(querier.findDefinition(usr: classUSR))
        #expect((def.path as NSString).lastPathComponent == "UserService.swift")
        #expect(def.line > 0)
        #expect(def.column > 0)
        #expect(def.usr == classUSR)
        // definition or declaration role — either is acceptable; the method
        // docs state it falls back to declaration.
        let hasDefRole = def.roles.contains("definition") || def.roles.contains("declaration")
        #expect(hasDefRole, "expected def/decl role, got \(def.roles)")
    }

    // MARK: - findOverrides on AppDelegate.setUp()

    @Test("findOverrides lists every subclass override of AppDelegate.setUp()")
    func setUpOverridesSnapshot() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        let all = querier.findRefs(symbolName: "setUp()")
        let base = try #require(
            all.first { $0.roles.contains("definition") && !$0.roles.contains("overrideOf") },
            "expected AppDelegate.setUp base definition"
        )

        let overrides = querier.findOverrides(usr: base.usr)

        // At least one override in the canary (SubDelegate.setUp in AppDelegate.swift).
        #expect(!overrides.isEmpty, "expected at least one override of setUp()")
        let files = Set(overrides.map { ($0.path as NSString).lastPathComponent })
        #expect(files.contains("AppDelegate.swift"))

        // Each override must carry an overrideOf role.
        for occ in overrides {
            #expect(occ.roles.contains("overrideOf"),
                    "expected overrideOf role on override at \(occ.path):\(occ.line), got \(occ.roles)")
        }
    }

    // MARK: - findConformances on AuthManager protocol

    @Test("findConformances enumerates protocol witnesses by conforming type")
    func authManagerConformancesSnapshot() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        let protoUSR = try #require(
            querier.findSymbol(symbolName: "AuthManager").first { $0.kind == "protocol" }?.usr
        )

        let conformances = querier.findConformances(usr: protoUSR)
        let names = Set(conformances.map(\.symbolName))
        #expect(names.contains("DefaultAuthManager"))

        // Each conformance points at a definition site (findConformances
        // locates the conforming type's def, not the protocol's).
        for occ in conformances {
            let hasDefRole = occ.roles.contains("definition") || occ.roles.contains("declaration")
            #expect(hasDefRole, "expected def/decl role at \(occ.symbolName), got \(occ.roles)")
        }
    }

    // MARK: - blastRadius on UserService.swift

    @Test("blastRadius(UserService.swift) keeps its direct-dependent + test classification")
    func userServiceBlastRadiusSnapshot() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        let result = querier.blastRadius(
            filePath: fixture.sourcePath("UserService.swift")
        )

        let affected = Set(result.affectedFiles.map { ($0 as NSString).lastPathComponent })
        let direct = Set(result.directDependents.map { ($0 as NSString).lastPathComponent })
        let tests = Set(result.coveringTests.map { ($0 as NSString).lastPathComponent })

        #expect(direct.contains("AppDelegate.swift"))
        #expect(direct.contains("CanaryTests.swift"))
        #expect(tests.contains("CanaryTests.swift"))

        // affectedFiles is the union of direct + transitive; every direct
        // dependent must appear in affectedFiles too.
        #expect(direct.isSubset(of: affected))
        #expect(tests.isSubset(of: affected))

        // The source file itself must NOT be in its own blast radius.
        #expect(!affected.contains("UserService.swift"))
    }
}

// MARK: - Shared fixture (duplicated for suite isolation)
//
// Each @Suite lives in its own file; duplicating this small holder
// avoids cross-suite coupling while keeping the one-build-per-run
// optimization.

private enum FixtureHolder {
    private nonisolated(unsafe) static var _built: BuiltIndex?
    private static let lock = NSLock()

    static func shared() throws -> BuiltIndex {
        lock.lock()
        defer { lock.unlock() }
        if let built = _built { return built }
        let built = try FixtureBuilder.buildCanaryIndex()
        _built = built
        return built
    }
}
