import Foundation
import Testing
@testable import xcindex

/// Coverage harness for the pinned apple/swift-log external fixture.
/// Thin wrapper over `ExternalFixtureHarness` — supplies the fixture
/// name and ground-truth/summary paths. Skips when no swift-log
/// checkout is available (opt-in locally, CI fetches explicitly).
///
/// swift-log is a deliberately small, macro-free SPM library. It
/// complements the TCA fixture (heavy macros + many deps) by exercising
/// the planner against plain Swift, where any regression in the
/// indexstore-only baseline surfaces cleanly.
@Suite("SwiftLogCoverageHarness", .serialized)
struct SwiftLogCoverageHarnessTests {
    @Test("swift-log fixture builds + reports per-symbol coverage (skips without checkout)")
    func runSwiftLogCoverageHarness() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // xcindexTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // service
            .deletingLastPathComponent() // repo root

        try ExternalFixtureHarness.run(
            name: "swift-log",
            groundTruthURL: repoRoot.appendingPathComponent("tests/fixtures/swift-log/swift-log.json"),
            summaryURL: repoRoot.appendingPathComponent("tests/coverage/swift-log-coverage-summary.json")
        )
    }
}
