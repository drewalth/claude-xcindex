import Foundation
import Testing
@testable import xcindex

/// Coverage harness for the pinned pointfreeco/swift-composable-architecture
/// external fixture. Delegates shape + logic to `ExternalFixtureHarness`;
/// this suite just supplies the fixture name and ground-truth/summary
/// paths. Skips when no TCA checkout is available (opt-in locally,
/// always present in CI via `scripts/fetch-fixture.sh tca`).
@Suite("TCACoverageHarness", .serialized)
struct TCACoverageHarnessTests {
    @Test("TCA fixture builds + reports per-symbol coverage (skips without checkout)")
    func runTCACoverageHarness() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // xcindexTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // service
            .deletingLastPathComponent() // repo root

        try ExternalFixtureHarness.run(
            name: "tca",
            groundTruthURL: repoRoot.appendingPathComponent("tests/fixtures/tca/tca.json"),
            summaryURL: repoRoot.appendingPathComponent("tests/coverage/tca-coverage-summary.json")
        )
    }
}
