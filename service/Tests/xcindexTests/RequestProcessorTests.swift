import Foundation
import Testing
@testable import xcindex

/// End-to-end wiring tests for `RequestProcessor.handle(.planRename)`.
///
/// These exercise the runtime orchestration added in step 7b: build the
/// indexstore plan, derive a workspace root, spawn/consult sourcekit-lsp,
/// and merge results via `RenamePlanner.reconcile`. Pure reconciliation
/// logic has its own unit tests in `RenamePlannerTests`; this suite
/// proves the wiring invokes the right pieces in the right order and
/// degrades gracefully when LSP returns nothing.
@Suite("RequestProcessor.planRename", .serialized)
struct RequestProcessorTests {
    @Test("planRename end-to-end wires indexstore plan through reconcile on canary fixture")
    func planRenameOnCanary() async throws {
        let fixture = try FixtureBuilder.buildCanaryIndex()
        let packageRoot = URL(fileURLWithPath: fixture.sourceDir)
            .deletingLastPathComponent() // Sources/CanaryApp -> Sources
            .deletingLastPathComponent() // Sources -> package root

        // Resolve UserService's USR by first looking up the symbol.
        let processor = RequestProcessor()
        let lookup = await processor.handle(Request(
            op: "findSymbol",
            indexStorePath: fixture.storePath,
            symbolName: "UserService"
        ))
        let userServiceUSR = try #require(lookup.symbols?.first?.usr)

        // Now the actual plan_rename request, including projectPath so
        // the processor can derive the workspace root for LSP.
        let response = await processor.handle(Request(
            op: "planRename",
            projectPath: packageRoot.path,
            indexStorePath: fixture.storePath,
            usr: userServiceUSR,
            newName: "AccountService"
        ))

        let plan = try #require(response.renamePlan)
        #expect(plan.refusal == nil)
        #expect(!plan.ranges.isEmpty)

        // LSP on the scratch-built SPM fixture typically returns []
        // (no compile_commands/BSP bridge), which either lands us at
        // `reconciliation_unavailable` (LSP binary missing or failed)
        // or `reconciliation_empty` (server answered with zero
        // locations). Either is acceptable — both communicate
        // "green-indexstore tiers are not independently verified."
        // If neither warning is present, the server upgraded at least
        // one range to green-verified, which is also fine.
        let hasDegradationWarning = plan.warnings.contains("reconciliation_unavailable")
            || plan.warnings.contains("reconciliation_empty")
        let hasVerified = plan.summary.greenVerified > 0
        #expect(hasDegradationWarning || hasVerified)
    }

    @Test("planRename returns refusal without touching LSP on invalid identifier")
    func refusalShortCircuitsLSP() async throws {
        let fixture = try FixtureBuilder.buildCanaryIndex()
        let processor = RequestProcessor()

        let response = await processor.handle(Request(
            op: "planRename",
            indexStorePath: fixture.storePath,
            usr: "s:irrelevant",
            newName: "class" // Swift keyword -> invalid_identifier refusal
        ))

        let plan = try #require(response.renamePlan)
        #expect(plan.refusal?.reason == "invalid_identifier")
        #expect(plan.ranges.isEmpty)
        #expect(plan.warnings.isEmpty) // never reached reconcile
    }
}

@Suite("WorkspaceDiagnostics")
struct WorkspaceDiagnosticsTests {
    @Test("SPM package is not classified as xcode-project")
    func spmPackageClassification() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(at: root.appendingPathComponent("Package.swift"), contents: "// swift-tools-version: 6.1\n")

        let diag = WorkspaceDiagnostics(root: root)
        #expect(!diag.isXcodeProject)
        #expect(!diag.hasBuildServerBridge)
    }

    @Test("xcodeproj without bridge flags as xcode-project + missing bridge")
    func xcodeProjectWithoutBridge() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("MyApp.xcodeproj"),
            withIntermediateDirectories: true
        )

        let diag = WorkspaceDiagnostics(root: root)
        #expect(diag.isXcodeProject)
        #expect(!diag.hasBuildServerBridge)
    }

    @Test("compile_commands.json counts as a build-server bridge")
    func xcodeProjectWithCompileCommands() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("MyApp.xcodeproj"),
            withIntermediateDirectories: true
        )
        try writeFile(at: root.appendingPathComponent("compile_commands.json"), contents: "[]")

        let diag = WorkspaceDiagnostics(root: root)
        #expect(diag.isXcodeProject)
        #expect(diag.hasBuildServerBridge)
    }

    @Test("mixed repo (Package.swift + xcodeproj) classifies as SPM")
    func mixedRepoTreatedAsSPM() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(at: root.appendingPathComponent("Package.swift"), contents: "// swift-tools-version: 6.1\n")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("MyApp.xcodeproj"),
            withIntermediateDirectories: true
        )

        let diag = WorkspaceDiagnostics(root: root)
        #expect(!diag.isXcodeProject)
    }

    // MARK: helpers

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcindex-wsdiag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
