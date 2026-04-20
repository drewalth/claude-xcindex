import Foundation
import IndexStoreDB
import Testing
@testable import xcindex

/// Unit + integration tests for the indexstore-only first pass of
/// `RenamePlanner`. These lock in:
///   • the happy-path tier assignment (green-indexstore by default)
///   • the refusal cases (env kill switch, invalid identifiers, SDK
///     paths, synthesized symbols) exposed as the `{reason, message,
///     remediation}` triple
///   • summary counting
///   • red-stale escalation for session-edited files
///   • JSON round-trip for the full plan shape
///
/// LSP-reconciliation tier labels (green-verified, yellow-*) are
/// covered in `RequestProcessorTests`. This suite intentionally
/// operates on the indexstore-only code path.
@Suite("RenamePlanner", .serialized)
struct RenamePlannerTests {
    // MARK: - Helpers

    private func fetchUserUSR(_ querier: IndexQuerier) throws -> (usr: String, path: String) {
        let refs = querier.findRefs(symbolName: "fetchUser(id:)")
        let def = try #require(
            refs.first { $0.roles.contains("definition") },
            "expected a definition occurrence for fetchUser(id:) in the canary"
        )
        return (usr: def.usr, path: def.path)
    }

    // MARK: - Happy path

    @Test("plan on fetchUser(id:) returns green-indexstore ranges with no refusal")
    func happyPath() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)
        let (usr, _) = try fetchUserUSR(querier)

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: usr, newName: "loadUser")

        #expect(plan.refusal == nil)
        #expect(!plan.ranges.isEmpty)
        #expect(plan.oldName == "fetchUser(id:)")
        #expect(plan.newName == "loadUser")
        #expect(plan.warnings.isEmpty)
        #expect(plan.ranges.allSatisfy { $0.tier == .greenIndexstore })
        #expect(plan.ranges.allSatisfy { $0.source == .indexstore })

        // Summary mirrors the tier distribution.
        #expect(plan.summary.greenIndexstore == plan.ranges.count)
        #expect(plan.summary.greenVerified == 0)
        #expect(plan.summary.redStale == 0)
    }

    // MARK: - Kill switch

    @Test("kill switch returns disabled_by_env refusal and no ranges")
    func killSwitch() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)
        let (usr, _) = try fetchUserUSR(querier)

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: true)
        let plan = planner.plan(usr: usr, newName: "loadUser")

        let refusal = try #require(plan.refusal)
        #expect(refusal.reason == "disabled_by_env")
        #expect(refusal.remediation.contains("XCINDEX_DISABLE_PLAN_RENAME"))
        #expect(plan.ranges.isEmpty)
    }

    // MARK: - Identifier validation

    @Test("keyword newName is refused with invalid_identifier + remediation text")
    func keywordNewName() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)
        let (usr, _) = try fetchUserUSR(querier)

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: usr, newName: "class")

        let refusal = try #require(plan.refusal)
        #expect(refusal.reason == "invalid_identifier")
        #expect(refusal.message.contains("class"))
        #expect(!refusal.remediation.isEmpty)
        #expect(plan.ranges.isEmpty)
    }

    @Test("empty newName is refused")
    func emptyNewName() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)
        let (usr, _) = try fetchUserUSR(querier)

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: usr, newName: "")

        let refusal = try #require(plan.refusal)
        #expect(refusal.reason == "invalid_identifier")
    }

    @Test("newName starting with a digit is refused")
    func leadingDigit() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)
        let (usr, _) = try fetchUserUSR(querier)

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: usr, newName: "1fetchUser")

        let refusal = try #require(plan.refusal)
        #expect(refusal.reason == "invalid_identifier")
    }

    @Test("newName with punctuation is refused")
    func punctuationInIdentifier() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)
        let (usr, _) = try fetchUserUSR(querier)

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: usr, newName: "fetch-user")

        let refusal = try #require(plan.refusal)
        #expect(refusal.reason == "invalid_identifier")
    }

    @Test("leading underscore is allowed")
    func leadingUnderscoreAllowed() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)
        let (usr, _) = try fetchUserUSR(querier)

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: usr, newName: "_fetchUser")

        #expect(plan.refusal == nil)
        #expect(!plan.ranges.isEmpty)
    }

    // MARK: - SDK-path refusal

    @Test("definition in an SDK path refuses with sdk_symbol_rename")
    func sdkPathRefusal() {
        // A real SPM fixture can't reliably surface a definition in an
        // SDK path — stdlib symbols aren't always indexed, and relying
        // on Foundation/UIKit makes the test toolchain-dependent.
        // Stub the backend so the refusal branch is exercised directly.
        let sdkPath = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/Foundation.swiftmodule/Foundation.swiftinterface"
        let stub = StubBackend(definition: OccurrenceResult(
            usr: "s:10Foundation3URLV",
            symbolName: "URL",
            path: sdkPath,
            line: 100,
            column: 14,
            roles: ["definition"]
        ))

        let planner = RenamePlanner(querier: stub, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: "s:10Foundation3URLV", newName: "Address")

        let refusal = try? #require(plan.refusal)
        #expect(refusal?.reason == "sdk_symbol_rename")
        #expect(refusal?.message.contains(sdkPath) == true)
        #expect(plan.oldName == "URL")
        #expect(plan.ranges.isEmpty)
    }

    @Test("empty definition path refuses with synthesized_symbol_not_renameable")
    func synthesizedSymbolRefusal() {
        // Compiler-synthesized members (Codable inits, property-wrapper
        // accessors) resolve to a definition occurrence with no
        // rewritable source range — IndexStoreDB reports path="" and/or
        // line=0. The planner must refuse rather than emit ranges that
        // point at nothing.
        let stub = StubBackend(definition: OccurrenceResult(
            usr: "s:7MyApp4FooV",
            symbolName: "Foo",
            path: "",
            line: 0,
            column: 0,
            roles: ["definition"]
        ))

        let planner = RenamePlanner(querier: stub, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: "s:7MyApp4FooV", newName: "Bar")

        let refusal = try? #require(plan.refusal)
        #expect(refusal?.reason == "synthesized_symbol_not_renameable")
        #expect(plan.ranges.isEmpty)
    }

    // MARK: - Unknown USR

    @Test("unknown USR returns a usr_not_found refusal with empty ranges")
    func unknownUSR() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: "c:@S@NotARealSymbol", newName: "renamed")

        let refusal = try #require(plan.refusal)
        #expect(refusal.reason == "usr_not_found")
        #expect(plan.ranges.isEmpty)
    }

    // MARK: - Session-edited files → red-stale

    @Test("session-edited file escalates every range in it to red-stale with session_edited reason")
    func sessionEditedEscalatesToRedStale() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)
        let (usr, defPath) = try fetchUserUSR(querier)

        // Mark the def's file as edited this session.
        let planner = RenamePlanner(querier: querier, editedFiles: [defPath], isDisabled: false)
        let plan = planner.plan(usr: usr, newName: "loadUser")

        #expect(plan.refusal == nil)
        let rangesInDefFile = plan.ranges.filter { $0.path == defPath }
        #expect(!rangesInDefFile.isEmpty, "expected at least one range in \(defPath)")
        for range in rangesInDefFile {
            #expect(range.tier == .redStale, "expected red-stale in edited file, got \(range.tier)")
            #expect(range.reasons.contains(.sessionEdited))
        }

        // Ranges in other files remain green-indexstore.
        let rangesOutside = plan.ranges.filter { $0.path != defPath }
        if !rangesOutside.isEmpty {
            #expect(rangesOutside.allSatisfy { $0.tier == .greenIndexstore })
        }

        // Summary counts reflect the split.
        #expect(plan.summary.redStale == rangesInDefFile.count)
        #expect(plan.summary.greenIndexstore == rangesOutside.count)
    }

    // MARK: - Role → reason mapping

    @Test("override occurrences carry the override reason")
    func overrideReason() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        // AppDelegate.setUp has a subclass override in the canary.
        let all = querier.findRefs(symbolName: "setUp()")
        let base = try #require(
            all.first { $0.roles.contains("definition") && !$0.roles.contains("overrideOf") }
        )

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: base.usr, newName: "setupApp")

        #expect(plan.refusal == nil)
        // Subclass overrides should tag .override, never .conformanceWitness —
        // the parent type here is a class, not a protocol.
        let hasOverride = plan.ranges.contains { $0.reasons.contains(.override) }
        #expect(hasOverride, "expected at least one override reason; ranges: \(plan.ranges.map { $0.reasons })")
        let hasWitness = plan.ranges.contains { $0.reasons.contains(.conformanceWitness) }
        #expect(!hasWitness, "class override should not be tagged conformance_witness")

        // Direct references (definition, calls) carry direct_reference.
        let hasDirect = plan.ranges.contains { $0.reasons.contains(.directReference) }
        #expect(hasDirect)
    }

    @Test("protocol requirement rename tags the witness with conformance_witness")
    func witnessReason() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        // AuthManager.authenticate(user:) is a protocol requirement;
        // DefaultAuthManager.authenticate(user:) is the witness.
        let all = querier.findRefs(symbolName: "authenticate(user:)")
        let requirement = try #require(
            all.first { $0.roles.contains("definition") && $0.path.hasSuffix("AuthManager.swift") && !$0.roles.contains("overrideOf") }
        )

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: requirement.usr, newName: "authorize")

        #expect(plan.refusal == nil)
        let witnessRanges = plan.ranges.filter { $0.reasons.contains(.conformanceWitness) }
        #expect(!witnessRanges.isEmpty, "expected at least one conformance_witness range; got \(plan.ranges.map { ($0.path, $0.line, $0.reasons) })")
        // A protocol witness must not also be tagged as a subclass override.
        #expect(!witnessRanges.contains { $0.reasons.contains(.override) })
    }

    @Test("extension header rename of the extended type tags extension_member")
    func extensionMemberReason() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)

        // DefaultAuthManager has an extension in AuthManager.swift.
        let all = querier.findRefs(symbolName: "DefaultAuthManager")
        let classDef = try #require(
            all.first { $0.roles.contains("definition") && !$0.roles.contains("extendedBy") }
        )

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: classDef.usr, newName: "FallbackAuthManager")

        #expect(plan.refusal == nil)
        let hasExtensionMember = plan.ranges.contains { $0.reasons.contains(.extensionMember) }
        #expect(hasExtensionMember, "expected at least one extension_member range; got \(plan.ranges.map { ($0.path, $0.line, $0.reasons) })")
    }

    // MARK: - JSON round-trip

    @Test("plan JSON round-trips through Codable with snake_case tier and reason codes")
    func jsonRoundTrip() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)
        let (usr, _) = try fetchUserUSR(querier)

        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)
        let plan = planner.plan(usr: usr, newName: "loadUser")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plan)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        // Tier + summary keys land in snake_case for consumers.
        #expect(jsonString.contains("\"green_indexstore\""))
        #expect(jsonString.contains("\"green-indexstore\"") ||
            jsonString.contains("green-indexstore"),
            "tier values should render as the snake/kebab-case raw form")

        // Round-trip preserves shape.
        let decoded = try JSONDecoder().decode(RenamePlan.self, from: data)
        #expect(decoded.usr == plan.usr)
        #expect(decoded.ranges.count == plan.ranges.count)
        #expect(decoded.summary.greenIndexstore == plan.summary.greenIndexstore)
    }

    // MARK: - Summary counting

    @Test("PlanSummary.counting tallies each tier correctly")
    func summaryCounting() {
        func range(_ tier: RenameTier) -> RenameRange {
            RenameRange(
                path: "/tmp/a.swift", line: 1, column: 1, endColumn: 5,
                tier: tier, reasons: [.directReference], module: nil, source: .indexstore
            )
        }
        let mixed: [RenameRange] = [
            range(.greenIndexstore), range(.greenIndexstore),
            range(.redStale),
            range(.yellowDisagreement),
            range(.yellowLspOnly),
            range(.greenVerified),
        ]
        let summary = PlanSummary.counting(mixed)
        #expect(summary.greenIndexstore == 2)
        #expect(summary.redStale == 1)
        #expect(summary.yellowDisagreement == 1)
        #expect(summary.yellowLspOnly == 1)
        #expect(summary.greenVerified == 1)
    }

    // MARK: - Range cap

    @Test("capped(at:) drops ranges past the limit and sets truncated=true, preserving summary")
    func cappedTruncation() {
        let ranges = (0 ..< 5).map { i in
            RenameRange(
                path: "/tmp/a.swift", line: i + 1, column: 1, endColumn: 5,
                tier: .greenIndexstore, reasons: [.directReference],
                module: nil, source: .indexstore
            )
        }
        let plan = Self.makePlan(ranges: ranges)
        let capped = plan.capped(at: 2)
        #expect(capped.ranges.count == 2)
        #expect(capped.truncated == true)
        // Summary is intentionally preserved so consumers see the true totals.
        #expect(capped.summary.greenIndexstore == 5)
    }

    @Test("capped(at:) is a no-op when ranges fit under the limit")
    func cappedNoOp() {
        let ranges = [
            RenameRange(
                path: "/tmp/a.swift", line: 1, column: 1, endColumn: 5,
                tier: .greenIndexstore, reasons: [.directReference],
                module: nil, source: .indexstore
            )
        ]
        let plan = Self.makePlan(ranges: ranges)
        let capped = plan.capped(at: 10)
        #expect(capped.ranges.count == 1)
        #expect(capped.truncated == false)
    }

    // MARK: - SDK path detection

    // MARK: - Reconciliation

    @Test("reconcile: both backends agree → green-verified")
    func reconcileBothAgree() {
        let indexstorePlan = Self.makePlan(ranges: [
            range(path: "/Users/x/App/UserService.swift", line: 10, col: 7, tier: .greenIndexstore)
        ])
        let lsp = [
            LSPRefLocation(
                path: "/Users/x/App/UserService.swift",
                line: 9, character: 6, endLine: 9, endCharacter: 17
            )
        ]
        let merged = RenamePlanner.reconcile(indexstorePlan, with: lsp)
        #expect(merged.ranges.count == 1)
        #expect(merged.ranges[0].tier == .greenVerified)
    }

    @Test("reconcile: indexstore only (LSP non-empty but missing this range) → yellow-disagreement")
    func reconcileIndexstoreOnly() {
        let indexstorePlan = Self.makePlan(ranges: [
            range(path: "/Users/x/App/A.swift", line: 10, col: 7, tier: .greenIndexstore)
        ])
        // LSP returned something, but for a different range
        let lsp = [
            LSPRefLocation(
                path: "/Users/x/App/B.swift",
                line: 0, character: 0, endLine: 0, endCharacter: 5
            )
        ]
        let merged = RenamePlanner.reconcile(indexstorePlan, with: lsp)
        let aRange = try? #require(merged.ranges.first { ($0.path as NSString).lastPathComponent == "A.swift" })
        #expect(aRange?.tier == .yellowDisagreement)
        #expect(aRange?.reasons.contains(.lspDidNotEcho) == true)
        // Must not carry `.sourcekitLspOnly` — that reason means the
        // opposite (LSP-only, indexstore didn't see it).
        #expect(aRange?.reasons.contains(.sourcekitLspOnly) == false)
    }

    @Test("reconcile: LSP only → yellow-lsp-only range added to plan")
    func reconcileLspOnlyAdded() {
        let indexstorePlan = Self.makePlan(ranges: [
            range(path: "/Users/x/App/A.swift", line: 10, col: 7, tier: .greenIndexstore)
        ])
        let lsp = [
            LSPRefLocation(
                path: "/Users/x/App/A.swift", line: 9, character: 6, endLine: 9, endCharacter: 17
            ),
            LSPRefLocation(
                path: "/Users/x/App/Macros.swift", line: 0, character: 4, endLine: 0, endCharacter: 15
            )
        ]
        let merged = RenamePlanner.reconcile(indexstorePlan, with: lsp)
        // 2 ranges: the A.swift (upgraded to green-verified) + Macros.swift (new yellow-lsp-only)
        #expect(merged.ranges.count == 2)
        let macroRange = try? #require(merged.ranges.first { ($0.path as NSString).lastPathComponent == "Macros.swift" })
        #expect(macroRange?.tier == .yellowLspOnly)
        #expect(macroRange?.source == .sourcekitLsp)
        #expect(macroRange?.reasons.contains(.sourcekitLspOnly) == true)
    }

    @Test("reconcile: LSP not consulted → warnings contains reconciliation_unavailable, tiers unchanged")
    func reconcileLspNotConsulted() {
        let plan = Self.makePlan(ranges: [
            range(path: "/Users/x/App/A.swift", line: 10, col: 7, tier: .greenIndexstore)
        ])
        let merged = RenamePlanner.reconcile(plan, with: [], lspConsulted: false)
        #expect(merged.warnings.contains(.reconciliationUnavailable))
        #expect(merged.ranges[0].tier == .greenIndexstore, "tier should not change when LSP was not consulted")
    }

    @Test("reconcile: LSP consulted but empty → reconciliation_empty warning, tiers preserved")
    func reconcileLspEmpty() {
        let plan = Self.makePlan(ranges: [
            range(path: "/Users/x/App/A.swift", line: 10, col: 7, tier: .greenIndexstore)
        ])
        let merged = RenamePlanner.reconcile(plan, with: [], lspConsulted: true)
        #expect(merged.warnings.contains(.reconciliationEmpty))
        // When LSP is consulted but returns nothing, don't downgrade —
        // the degraded-backend case is distinct from an actual disagreement.
        #expect(merged.ranges[0].tier == .greenIndexstore)
    }

    @Test("reconcile: red-stale ranges stay red-stale even if LSP agrees")
    func reconcileRedStaleStays() {
        let plan = Self.makePlan(ranges: [
            range(path: "/Users/x/App/A.swift", line: 10, col: 7, tier: .redStale, reasons: [.directReference, .sessionEdited])
        ])
        let lsp = [
            LSPRefLocation(path: "/Users/x/App/A.swift", line: 9, character: 6, endLine: 9, endCharacter: 17)
        ]
        let merged = RenamePlanner.reconcile(plan, with: lsp)
        #expect(merged.ranges[0].tier == .redStale, "session-edited ranges stay red-stale regardless of LSP agreement")
    }

    // MARK: - Reconciliation test helpers

    private func range(
        path: String, line: Int, col: Int, tier: RenameTier,
        reasons: [RenameReason] = [.directReference]
    ) -> RenameRange {
        RenameRange(
            path: path, line: line, column: col, endColumn: col + 11,
            tier: tier, reasons: reasons, module: nil, source: .indexstore
        )
    }

    private static func makePlan(ranges: [RenameRange]) -> RenamePlan {
        RenamePlan(
            usr: "c:@test",
            oldName: "UserService",
            newName: "AccountService",
            generatedAt: "2026-04-20T00:00:00Z",
            indexFreshness: IndexFreshness(lastBuilt: nil, filesEditedThisSession: 0),
            ranges: ranges,
            summary: PlanSummary.counting(ranges),
            refusal: nil,
            warnings: []
        )
    }

    @Test("isSDKPath heuristic recognizes Xcode, CommandLineTools, and user toolchain paths")
    func sdkHeuristic() {
        #expect(RenamePlanner.isSDKPath("/Applications/Xcode.app/Contents/Developer/usr/lib/swift/Swift.swiftmodule/x.swiftinterface"))
        #expect(RenamePlanner.isSDKPath("/Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/usr/lib/swift/Foundation.swiftmodule/x.swiftinterface"))
        #expect(RenamePlanner.isSDKPath("/Library/Developer/CommandLineTools/usr/lib/swift/Darwin.swiftmodule"))
        #expect(RenamePlanner.isSDKPath("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"))
        #expect(RenamePlanner.isSDKPath("/Users/me/Library/Developer/Toolchains/swift-5.10.0-RELEASE.xctoolchain/usr/lib/swift/Foundation.swiftmodule"))
        #expect(RenamePlanner.isSDKPath("/Users/me/.swiftly/toolchains/5.9.2/usr/lib/swift/Darwin.swiftmodule"))

        #expect(!RenamePlanner.isSDKPath("/Users/me/Projects/App/Sources/UserService.swift"))
        #expect(!RenamePlanner.isSDKPath("/tmp/my-app/Sources/Main.swift"))
        #expect(!RenamePlanner.isSDKPath(""))
    }
}

// MARK: - Stub backend

/// Minimal `RenamePlannerQueryBackend` stub for unit tests that need
/// to drive refusal branches (SDK / synthesized) without constructing
/// a real IndexStoreDB fixture.
private struct StubBackend: RenamePlannerQueryBackend {
    let definition: OccurrenceResult?

    func findDefinition(usr _: String) -> OccurrenceResult? {
        definition
    }

    func findOverrides(usr _: String) -> [OccurrenceResult] {
        []
    }

    func occurrences(ofUSR _: String, roles _: SymbolRole) -> [SymbolOccurrence] {
        []
    }
}

// MARK: - Shared fixture

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
