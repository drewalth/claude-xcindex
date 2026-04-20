import Foundation
import Testing
@testable import xcindex

// MARK: - ExternalFixtureHarness
//
// Shared runner for external-fixture coverage tests (TCA, swift-log,
// and any additional SPM projects we pin for regression). Fixture-
// specific test suites call `ExternalFixtureHarness.run(...)` with a
// fixture name + ground-truth path + summary path; the runner handles
// build + USR resolution + recall/precision computation + summary
// emission + the "verified-symbols-must-hit-1.0" gate uniformly.
//
// The canary has its own bespoke harness (CoverageHarnessTests) that
// enforces flat `aggregate.recall == 1.0` — the canary is the smallest,
// cleanest fixture and any regression there is a real bug. External
// fixtures are bigger and messier (protocol witnesses, macros); we
// only gate on entries explicitly marked `needs_verification: false`,
// keeping stub entries informational until a reviewer curates them.

// MARK: - Ground-truth shapes (external fixtures)

struct ExternalGroundTruth: Codable {
    let fixture: String
    let fixtureSource: String
    let upstream: ExternalUpstream
    let curationMethod: String
    let generatedAt: String
    let caveats: [String]
    let symbols: [ExternalSymbol]

    enum CodingKeys: String, CodingKey {
        case fixture
        case fixtureSource = "fixture_source"
        case upstream
        case curationMethod = "curation_method"
        case generatedAt = "generated_at"
        case caveats
        case symbols
    }
}

struct ExternalUpstream: Codable {
    let tag: String
    let sha: String
    let pinnedOn: String

    enum CodingKeys: String, CodingKey {
        case tag
        case sha
        case pinnedOn = "pinned_on"
    }
}

struct ExternalSymbol: Codable {
    let description: String
    let symbolQuery: String
    let kind: String
    let newName: String
    let needsVerification: Bool
    let expectedRanges: [ExternalRange]

    enum CodingKeys: String, CodingKey {
        case description
        case symbolQuery = "symbol_query"
        case kind
        case newName = "new_name"
        case needsVerification = "needs_verification"
        case expectedRanges = "expected_ranges"
    }
}

struct ExternalRange: Codable, Hashable {
    let pathBasename: String
    let line: Int
    let column: Int
    let role: String

    enum CodingKeys: String, CodingKey {
        case pathBasename = "path_basename"
        case line
        case column
        case role
    }
}

// MARK: - Summary shapes

struct ExternalSummary: Codable {
    let fixture: String
    let upstream: ExternalUpstream
    let toolchain: String
    let generatedAt: String
    let perSymbol: [ExternalSymbolResult]
    let aggregate: ExternalAggregate

    enum CodingKeys: String, CodingKey {
        case fixture
        case upstream
        case toolchain
        case generatedAt = "generated_at"
        case perSymbol = "per_symbol"
        case aggregate
    }
}

struct ExternalSymbolResult: Codable {
    let symbolQuery: String
    let kind: String
    let needsVerification: Bool
    let expectedCount: Int
    let retrievedCount: Int
    let truePositives: Int
    let falseNegatives: [String]
    let falsePositives: [String]
    let recall: Double
    let precision: Double
    let refusalReason: String?
    /// Wall time for the `RenamePlanner.plan(...)` call, in
    /// milliseconds. Measured after the fixture has been built so the
    /// number reflects a warm-cache plan cost, not first-run index
    /// open time. Omitted (encoded as null) when USR resolution
    /// failed before `plan` was invoked.
    let planElapsedMs: Double?

    enum CodingKeys: String, CodingKey {
        case symbolQuery = "symbol_query"
        case kind
        case needsVerification = "needs_verification"
        case expectedCount = "expected_count"
        case retrievedCount = "retrieved_count"
        case truePositives = "true_positives"
        case falseNegatives = "false_negatives"
        case falsePositives = "false_positives"
        case recall
        case precision
        case refusalReason = "refusal_reason"
        case planElapsedMs = "plan_elapsed_ms"
    }
}

struct ExternalAggregate: Codable {
    let verifiedSymbolCount: Int
    let stubSymbolCount: Int
    let expectedTotal: Int
    let retrievedTotal: Int
    let truePositivesTotal: Int
    let recall: Double
    let precision: Double
    /// Max wall time across every `plan` call in this run (ms). Useful
    /// as a headline SLO number; p50/p95 would need more symbols
    /// than current fixtures carry to be meaningful.
    let maxPlanElapsedMs: Double?

    enum CodingKeys: String, CodingKey {
        case verifiedSymbolCount = "verified_symbol_count"
        case stubSymbolCount = "stub_symbol_count"
        case expectedTotal = "expected_total"
        case retrievedTotal = "retrieved_total"
        case truePositivesTotal = "true_positives_total"
        case recall
        case precision
        case maxPlanElapsedMs = "max_plan_elapsed_ms"
    }
}

// MARK: - Runner

enum ExternalFixtureHarness {
    /// Warm-build SLO for a single `RenamePlanner.plan(...)` call on an
    /// external fixture, in milliseconds. The design target is "5s
    /// warm on TCA"; verified (non-stub) symbols must stay under this
    /// bound. Override via `XCINDEX_PLAN_SLO_MS` when profiling on a
    /// slower host. Stub symbols are informational — their timings
    /// land in the summary but never fail the run.
    static let defaultPlanSloMs: Double = 5000

    /// Run the coverage harness for a named external fixture. Fails
    /// loudly when the checkout is missing unless
    /// `XCINDEX_ALLOW_FIXTURE_SKIP=1` is set — a silent skip on CI
    /// would mask a fetch-script regression as a passing run with
    /// zero assertions executed.
    ///
    /// - Parameters:
    ///   - name: Short fixture identifier (e.g. "tca", "swift-log").
    ///     Used for `FixtureBuilder.buildExternalIndexIfAvailable` and
    ///     env-var discovery.
    ///   - groundTruthURL: Absolute path to the fixture's JSON ground
    ///     truth file in `tests/fixtures/<name>/`.
    ///   - summaryURL: Absolute path where the per-run summary is
    ///     written. CI uploads this as an artifact.
    static func run(
        name: String,
        groundTruthURL: URL,
        summaryURL: URL
    ) throws {
        guard let fixture = try FixtureBuilder.buildExternalIndexIfAvailable(name: name) else {
            let env = ProcessInfo.processInfo.environment
            if env["XCINDEX_ALLOW_FIXTURE_SKIP"] == "1" {
                return
            }
            Issue.record("""
            External fixture '\(name)' is not checked out at the expected location. \
            Run `scripts/fetch-fixture.sh \(name)` to populate it, or set \
            XCINDEX_ALLOW_FIXTURE_SKIP=1 to skip this suite locally. \
            A silent skip would otherwise register as a passing test with zero assertions.
            """)
            return
        }

        let truth = try JSONDecoder().decode(
            ExternalGroundTruth.self,
            from: Data(contentsOf: groundTruthURL)
        )

        let querier = try IndexQuerier(storePath: fixture.storePath)
        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)

        var perSymbol: [ExternalSymbolResult] = []
        var verifiedCount = 0
        var stubCount = 0
        var expectedTotal = 0
        var retrievedTotal = 0
        var truePositivesTotal = 0
        var maxElapsedMs: Double = 0

        for symbol in truth.symbols {
            if symbol.needsVerification {
                stubCount += 1
            } else {
                verifiedCount += 1
            }

            guard let usr = resolveUSR(for: symbol, querier: querier) else {
                perSymbol.append(ExternalSymbolResult(
                    symbolQuery: symbol.symbolQuery,
                    kind: symbol.kind,
                    needsVerification: symbol.needsVerification,
                    expectedCount: symbol.expectedRanges.count,
                    retrievedCount: 0,
                    truePositives: 0,
                    falseNegatives: symbol.expectedRanges.map(key(expected:)),
                    falsePositives: [],
                    recall: symbol.expectedRanges.isEmpty ? 1.0 : 0.0,
                    precision: 1.0,
                    refusalReason: "usr_not_found",
                    planElapsedMs: nil
                ))
                continue
            }

            let start = DispatchTime.now()
            let plan = planner.plan(usr: usr, newName: symbol.newName)
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let elapsedMs = Double(elapsedNs) / 1_000_000
            maxElapsedMs = max(maxElapsedMs, elapsedMs)

            let expectedKeys = Set(symbol.expectedRanges.map(key(expected:)))
            let retrievedKeys = Set(plan.ranges.map(key(range:)))
            let truePositives = expectedKeys.intersection(retrievedKeys)
            let falseNegatives = expectedKeys.subtracting(retrievedKeys).sorted()
            let falsePositives = retrievedKeys.subtracting(expectedKeys).sorted()

            let recall = expectedKeys.isEmpty
                ? 1.0
                : Double(truePositives.count) / Double(expectedKeys.count)
            let precision = retrievedKeys.isEmpty
                ? 1.0
                : Double(truePositives.count) / Double(retrievedKeys.count)

            perSymbol.append(ExternalSymbolResult(
                symbolQuery: symbol.symbolQuery,
                kind: symbol.kind,
                needsVerification: symbol.needsVerification,
                expectedCount: expectedKeys.count,
                retrievedCount: retrievedKeys.count,
                truePositives: truePositives.count,
                falseNegatives: falseNegatives,
                falsePositives: falsePositives,
                recall: recall,
                precision: precision,
                refusalReason: plan.refusal?.reason,
                planElapsedMs: elapsedMs
            ))

            expectedTotal += expectedKeys.count
            retrievedTotal += retrievedKeys.count
            truePositivesTotal += truePositives.count
        }

        let aggregateRecall = expectedTotal == 0
            ? 1.0
            : Double(truePositivesTotal) / Double(expectedTotal)
        let aggregatePrecision = retrievedTotal == 0
            ? 1.0
            : Double(truePositivesTotal) / Double(retrievedTotal)

        let summary = ExternalSummary(
            fixture: truth.fixture,
            upstream: truth.upstream,
            toolchain: toolchainDescription(),
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            perSymbol: perSymbol,
            aggregate: ExternalAggregate(
                verifiedSymbolCount: verifiedCount,
                stubSymbolCount: stubCount,
                expectedTotal: expectedTotal,
                retrievedTotal: retrievedTotal,
                truePositivesTotal: truePositivesTotal,
                recall: aggregateRecall,
                precision: aggregatePrecision,
                maxPlanElapsedMs: perSymbol.isEmpty ? nil : maxElapsedMs
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: summaryURL)

        let sloMs = Self.resolvePlanSlo()
        for result in perSymbol where !result.needsVerification {
            // Authoring guard: a verified entry with no expected_ranges
            // auto-passes the recall check (1.0 / 1.0) — that's a
            // curation bug, not a green signal. Flip needs_verification
            // back to true or add at least one ground-truth range.
            #expect(result.expectedCount > 0,
                    "\(truth.fixture) verified symbol '\(result.symbolQuery)' has needs_verification=false but no expected_ranges — either curate the ground truth or set needs_verification=true.")
            #expect(result.recall == 1.0,
                    "\(truth.fixture) verified symbol '\(result.symbolQuery)' dropped to recall=\(result.recall); missing: \(result.falseNegatives)")
            if let elapsed = result.planElapsedMs {
                #expect(elapsed <= sloMs,
                        "\(truth.fixture) verified symbol '\(result.symbolQuery)' plan took \(elapsed) ms (SLO: \(sloMs) ms). Override via XCINDEX_PLAN_SLO_MS when profiling on a slower host.")
            }
        }
    }

    private static func resolvePlanSlo() -> Double {
        if let override = ProcessInfo.processInfo.environment["XCINDEX_PLAN_SLO_MS"],
           let parsed = Double(override), parsed > 0 {
            return parsed
        }
        return defaultPlanSloMs
    }

    // MARK: - Helpers

    private static func resolveUSR(
        for symbol: ExternalSymbol,
        querier: IndexQuerier
    ) -> String? {
        if symbol.kind.contains("Method") {
            let refs = querier.findRefs(symbolName: symbol.symbolQuery)
            return refs.first(where: { $0.roles.contains("definition") })?.usr
        }
        return querier.findSymbol(symbolName: symbol.symbolQuery)
            .first(where: { $0.kind == symbol.kind })?.usr
    }

    private static func key(basename: String, line: Int, column: Int) -> String {
        "\(basename):\(line):\(column)"
    }

    private static func key(range: RenameRange) -> String {
        key(basename: (range.path as NSString).lastPathComponent, line: range.line, column: range.column)
    }

    private static func key(expected: ExternalRange) -> String {
        key(basename: expected.pathBasename, line: expected.line, column: expected.column)
    }

    private static func toolchainDescription() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["TOOLCHAIN_VERSION"] ?? env["SWIFT_VERSION"] ?? "unknown"
    }
}
