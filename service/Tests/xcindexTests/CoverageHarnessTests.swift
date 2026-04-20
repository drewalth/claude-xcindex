import Foundation
import Testing
@testable import xcindex

/// Coverage harness for the canary fixture.
///
/// Reads `tests/coverage/canary.json`, runs `RenamePlanner` against
/// each target symbol, computes recall + precision against the
/// hand-verified expected ranges, and writes a summary to
/// `tests/coverage/coverage-summary.json` (relative to the repo root).
///
/// This is v1.1 step 3. The Swift-version matrix + CI workflow land
/// in step 12; this suite is the logic underneath that workflow.
///
/// Range comparison uses a normalized tuple of
/// `(path_basename, line, column)` — path prefixes are randomized per
/// test run (SwiftPM scratch dir), so full paths aren't comparable.
@Suite("CoverageHarness", .serialized)
struct CoverageHarnessTests {
    // MARK: - Ground truth shapes (decoded from canary.json)

    struct GroundTruth: Codable {
        let fixture: String
        let fixtureSource: String
        let generatedAt: String
        let curationMethod: String
        let caveats: [String]
        let symbols: [GroundTruthSymbol]

        enum CodingKeys: String, CodingKey {
            case fixture
            case fixtureSource = "fixture_source"
            case generatedAt = "generated_at"
            case curationMethod = "curation_method"
            case caveats
            case symbols
        }
    }

    struct GroundTruthSymbol: Codable {
        let description: String
        let symbolQuery: String
        let kind: String
        let newName: String
        let expectedRanges: [GroundTruthRange]

        enum CodingKeys: String, CodingKey {
            case description
            case symbolQuery = "symbol_query"
            case kind
            case newName = "new_name"
            case expectedRanges = "expected_ranges"
        }
    }

    struct GroundTruthRange: Codable, Hashable {
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

    // MARK: - Coverage summary shapes (written out)

    struct CoverageSummary: Codable {
        let fixture: String
        let toolchain: String
        let generatedAt: String
        let perSymbol: [SymbolResult]
        let aggregate: AggregateResult

        enum CodingKeys: String, CodingKey {
            case fixture
            case toolchain
            case generatedAt = "generated_at"
            case perSymbol = "per_symbol"
            case aggregate
        }
    }

    struct SymbolResult: Codable {
        let symbolQuery: String
        let kind: String
        let expectedCount: Int
        let retrievedCount: Int
        let truePositives: Int
        let falseNegatives: [String]
        let falsePositives: [String]
        let recall: Double
        let precision: Double

        enum CodingKeys: String, CodingKey {
            case symbolQuery = "symbol_query"
            case kind
            case expectedCount = "expected_count"
            case retrievedCount = "retrieved_count"
            case truePositives = "true_positives"
            case falseNegatives = "false_negatives"
            case falsePositives = "false_positives"
            case recall
            case precision
        }
    }

    struct AggregateResult: Codable {
        let expectedTotal: Int
        let retrievedTotal: Int
        let truePositivesTotal: Int
        let recall: Double
        let precision: Double

        enum CodingKeys: String, CodingKey {
            case expectedTotal = "expected_total"
            case retrievedTotal = "retrieved_total"
            case truePositivesTotal = "true_positives_total"
            case recall
            case precision
        }
    }

    // MARK: - Paths

    private static func repoRoot() -> URL {
        // This file lives at service/Tests/xcindexTests/CoverageHarnessTests.swift.
        // Walk up four levels to the repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // xcindexTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // service
            .deletingLastPathComponent() // repo root
    }

    private static func groundTruthURL() -> URL {
        repoRoot().appendingPathComponent("tests/coverage/canary.json")
    }

    private static func summaryURL() -> URL {
        repoRoot().appendingPathComponent("tests/coverage/coverage-summary.json")
    }

    // MARK: - Range normalization

    /// `(basename:line:column)` tuple for comparing tool output to ground truth.
    private static func key(basename: String, line: Int, column: Int) -> String {
        "\(basename):\(line):\(column)"
    }

    private static func key(range: RenameRange) -> String {
        let basename = (range.path as NSString).lastPathComponent
        return key(basename: basename, line: range.line, column: range.column)
    }

    private static func key(expected: GroundTruthRange) -> String {
        key(basename: expected.pathBasename, line: expected.line, column: expected.column)
    }

    // MARK: - Harness

    @Test("canary.json recall + precision report; writes coverage-summary.json")
    func runCoverageHarness() throws {
        let fixture = try FixtureHolder.shared()
        let querier = try IndexQuerier(storePath: fixture.storePath)
        let planner = RenamePlanner(querier: querier, editedFiles: [], isDisabled: false)

        let truthURL = Self.groundTruthURL()
        let truthData = try Data(contentsOf: truthURL)
        let decoder = JSONDecoder()
        let truth = try decoder.decode(GroundTruth.self, from: truthData)

        var perSymbol: [SymbolResult] = []
        var expectedTotal = 0
        var retrievedTotal = 0
        var truePositivesTotal = 0

        for symbol in truth.symbols {
            // Resolve USR via findSymbol + findRefs (matches how Claude
            // would obtain a USR in practice).
            let usr = try resolveUSR(symbol: symbol, querier: querier)

            let plan = planner.plan(usr: usr, newName: symbol.newName)
            #expect(plan.refusal == nil,
                    "\(symbol.symbolQuery): unexpected refusal \(plan.refusal?.reason ?? "")")

            let expectedKeys = Set(symbol.expectedRanges.map(Self.key(expected:)))
            let retrievedKeys = Set(plan.ranges.map(Self.key(range:)))
            let truePositives = expectedKeys.intersection(retrievedKeys)
            let falseNegatives = expectedKeys.subtracting(retrievedKeys).sorted()
            let falsePositives = retrievedKeys.subtracting(expectedKeys).sorted()

            let recall = expectedKeys.isEmpty
                ? 1.0
                : Double(truePositives.count) / Double(expectedKeys.count)
            let precision = retrievedKeys.isEmpty
                ? 1.0
                : Double(truePositives.count) / Double(retrievedKeys.count)

            perSymbol.append(SymbolResult(
                symbolQuery: symbol.symbolQuery,
                kind: symbol.kind,
                expectedCount: expectedKeys.count,
                retrievedCount: retrievedKeys.count,
                truePositives: truePositives.count,
                falseNegatives: falseNegatives,
                falsePositives: falsePositives,
                recall: recall,
                precision: precision
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

        let summary = CoverageSummary(
            fixture: truth.fixture,
            toolchain: toolchainDescription(),
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            perSymbol: perSymbol,
            aggregate: AggregateResult(
                expectedTotal: expectedTotal,
                retrievedTotal: retrievedTotal,
                truePositivesTotal: truePositivesTotal,
                recall: aggregateRecall,
                precision: aggregatePrecision
            )
        )

        // Write coverage-summary.json for CI artifact collection.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        try data.write(to: Self.summaryURL())

        // Assertion floor: recall must be 1.0 on the canary. The canary
        // is the smallest, cleanest fixture and contains no macro or
        // cross-language edge cases — anything less than perfect recall
        // here is a regression, not a coverage gap.
        #expect(aggregateRecall == 1.0,
                "canary recall < 1.0 — per-symbol: \(perSymbol.map { "\($0.symbolQuery)=\($0.recall)" }.joined(separator: ", "))")
    }

    // MARK: - Helpers

    private func resolveUSR(
        symbol: GroundTruthSymbol,
        querier: IndexQuerier
    ) throws -> String {
        // Method USRs are resolved through findRefs (IndexStoreDB stores
        // method names in full-selector form); class/protocol USRs land
        // cleanly via findSymbol.
        if symbol.kind.contains("Method") {
            let refs = querier.findRefs(symbolName: symbol.symbolQuery)
            let def = try #require(
                refs.first { $0.roles.contains("definition") },
                "no definition for method \(symbol.symbolQuery)"
            )
            return def.usr
        }

        let candidates = querier.findSymbol(symbolName: symbol.symbolQuery)
        let match = try #require(
            candidates.first { $0.kind == symbol.kind },
            "no \(symbol.kind) candidate for \(symbol.symbolQuery); got \(candidates.map(\.kind))"
        )
        return match.usr
    }

    private func toolchainDescription() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["TOOLCHAIN_VERSION"] ?? env["SWIFT_VERSION"] ?? "unknown"
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
