import Foundation
import Testing
@testable import xcindex

/// Integration tests against a real IndexStore produced by compiling the
/// canary fixture. One happy-path test per MCP-exposed query. If you add
/// a new tool, add a test here.
///
/// These tests require Xcode (`libIndexStore.dylib` lookup) and a
/// working `swiftc` on PATH. They are the heavier tests in the suite;
/// the suite shares one built index via `FixtureHolder` to avoid
/// re-building for each test.
@Suite("IndexQuerier", .serialized)
struct IndexQuerierTests {
    // MARK: - findSymbol

    @Test("findSymbol returns a class symbol with kind and language")
    func findSymbolClass() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        let results = querier.findSymbol(symbolName: "UserService")
        #expect(!results.isEmpty, "expected at least one UserService symbol")

        let cls = results.first { $0.kind == "class" }
        #expect(cls != nil, "expected a class-kind match among: \(results.map(\.kind))")
        #expect(cls?.language == "swift")
        #expect(cls?.definitionPath.map { ($0 as NSString).lastPathComponent } == "UserService.swift")
    }

    // MARK: - findRefs

    @Test("findRefs resolves name → USRs → all occurrences")
    func findRefsReturnsCallSites() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        // IndexStoreDB stores Swift method names with their argument
        // labels baked in ("fetchUser(id:)"), so an exact-name query
        // needs the full signature.
        let refs = querier.findRefs(symbolName: "fetchUser(id:)")

        // There's a definition in UserService.swift and calls in
        // AppDelegate.swift + CanaryTests.swift.
        let files = Set(refs.map { ($0.path as NSString).lastPathComponent })
        #expect(files.contains("UserService.swift"))
        #expect(files.contains("AppDelegate.swift"))
        #expect(files.contains("CanaryTests.swift"))

        // Every result carries a non-empty USR and at least one role.
        for ref in refs {
            #expect(!ref.usr.isEmpty)
            #expect(!ref.roles.isEmpty)
        }
    }

    // MARK: - findDefinition

    @Test("findDefinition returns the canonical definition site for a USR")
    func findDefinitionForUSR() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        let candidates = querier.findSymbol(symbolName: "UserService")
        let classUSR = try #require(candidates.first { $0.kind == "class" }?.usr)

        let def = try #require(querier.findDefinition(usr: classUSR))
        #expect((def.path as NSString).lastPathComponent == "UserService.swift")
        #expect(def.line > 0)
        let hasDefRole = def.roles.contains("definition") || def.roles.contains("declaration")
        #expect(hasDefRole, "expected a definition/declaration role, got \(def.roles)")
    }

    // MARK: - findOverrides

    @Test("findOverrides returns subclass implementations")
    func findOverridesForSetUp() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        // Swift method names are stored with their argument labels:
        // `setUp()` rather than `setUp`. Use the full form.
        let allOccurrences = querier.findRefs(symbolName: "setUp()")
        let baseSetUp = try #require(
            allOccurrences.first { ref in
                // The base is the definition in AppDelegate.setUp, not
                // the override in SubDelegate.setUp. Pick the one whose
                // roles include a definition role.
                ref.roles.contains("definition") && !ref.roles.contains("overrideOf")
            },
            "expected AppDelegate.setUp base definition, got \(allOccurrences.map { "\($0.roles) @ \($0.line)" })"
        )

        let overrides = querier.findOverrides(usr: baseSetUp.usr)
        let overrideFiles = Set(overrides.map { ($0.path as NSString).lastPathComponent })
        #expect(overrideFiles.contains("AppDelegate.swift"),
                "expected SubDelegate.setUp() override in AppDelegate.swift, got \(overrideFiles)")
    }

    // MARK: - findConformances

    @Test("findConformances returns types that conform to a protocol")
    func findConformancesForAuthManager() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        let candidates = querier.findSymbol(symbolName: "AuthManager")
        let protoUSR = try #require(candidates.first { $0.kind == "protocol" }?.usr)

        let conformances = querier.findConformances(usr: protoUSR)
        let names = Set(conformances.map(\.symbolName))
        #expect(names.contains("DefaultAuthManager"),
                "expected DefaultAuthManager conformance, got \(names)")
    }

    // MARK: - blastRadius

    @Test("blastRadius for UserService.swift surfaces dependents + tests")
    func blastRadiusIncludesDependents() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        let result = querier.blastRadius(
            filePath: fixture.sourcePath("UserService.swift")
        )
        let directNames = Set(result.directDependents.map { ($0 as NSString).lastPathComponent })
        #expect(directNames.contains("AppDelegate.swift"))
        #expect(directNames.contains("CanaryTests.swift"))

        let testNames = Set(result.coveringTests.map { ($0 as NSString).lastPathComponent })
        #expect(testNames.contains("CanaryTests.swift"),
                "CanaryTests.swift should be classified as a covering test")
    }

    // MARK: - status

    @Test("status returns an mtime summary string for an existing store")
    func statusSummarizesExistingStore() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        let status = querier.status(storePath: fixture.storePath)
        #expect(status.indexStorePath == fixture.storePath)
        #expect(status.indexMtime != nil)
        #expect(status.summary.contains("Index store found at"))
    }
}

// MARK: - Shared fixture

/// Builds the canary index exactly once per test-process run. Swift
/// Testing runs suites in parallel by default, but this suite is
/// marked `.serialized` and shares the built index across tests to
/// avoid the ~1s swiftc build per test.
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
