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
        let hasDegradationWarning = plan.warnings.contains(.reconciliationUnavailable)
            || plan.warnings.contains(.reconciliationEmpty)
        let hasVerified = plan.summary.greenVerified > 0
        #expect(hasDegradationWarning || hasVerified)
    }

    @Test("dead LSP client is evicted from the cache after the subprocess exits mid-request")
    func deadClientEviction() async throws {
        // Stand up a fake sourcekit-lsp that exits the moment a
        // textDocument/references request lands. Two consecutive
        // planRename calls should each end up launching their own
        // subprocess — if the cache held onto the corpse the second
        // call would fail with `.sourcekitLspNotRunning` instead of
        // re-launching. Injecting the binary through the actor's test
        // hook avoids mutating `SOURCEKIT_LSP_PATH` — that env var is
        // process-global and would leak into other test suites
        // running in parallel.
        let fake = try FakeLSPServer(mode: .exitAfterInit)

        let fixture = try FixtureBuilder.buildCanaryIndex()
        let packageRoot = URL(fileURLWithPath: fixture.sourceDir)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let processor = RequestProcessor()
        await processor.setLspBinaryOverrideForTesting(fake.binaryURL)

        let lookup = await processor.handle(Request(
            op: "findSymbol",
            indexStorePath: fixture.storePath,
            symbolName: "UserService"
        ))
        let usr = try #require(lookup.symbols?.first?.usr)

        let request = Request(
            op: "planRename",
            projectPath: packageRoot.path,
            indexStorePath: fixture.storePath,
            usr: usr,
            newName: "AccountService"
        )

        let first = await processor.handle(request)
        _ = try #require(first.renamePlan)
        // After the first call, the subprocess exited mid-request and
        // the cache should be empty again.
        let afterFirst = await processor.lspClientCacheCount()
        #expect(afterFirst == 0, "dead client was not evicted; cache holds \(afterFirst) entries")

        let second = await processor.handle(request)
        let plan2 = try #require(second.renamePlan)
        // A stale cache would re-hand the dead client to the second
        // call, which would throw .notRunning at the references-check
        // guard. Assert the opposite shape: either the subprocess died
        // again (re-launch happened) or it answered — never .notRunning.
        #expect(!plan2.warnings.contains(.sourcekitLspNotRunning),
                "second planRename saw sourcekit_lsp_not_running — cache held a dead client")
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

@Suite("RequestProcessor.diagnoseLSPError")
struct DiagnoseLSPErrorTests {
    @Test("each LSPClientError case maps to a distinct warning code")
    func taxonomyIsExhaustive() {
        let cases: [(LSPClientError, RenameWarning)] = [
            (.binaryNotFound, .sourcekitLspNotFound),
            (.binaryNotExecutable(path: "/bin/false"), .sourcekitLspBinaryNotExecutable),
            (.initializeTimeout, .sourcekitLspLaunchFailed),
            (.referencesTimeout, .sourcekitLspTimeout),
            (.notRunning, .sourcekitLspNotRunning),
            (.processTerminated, .sourcekitLspProcessTerminated),
            (.fileReadFailed(path: "/x", underlying: "boom"), .lspFileReadFailed),
            (.protocolError("boom"), .sourcekitLspProtocolError),
        ]
        for (error, expectedCode) in cases {
            let result = RequestProcessor.diagnoseLSPError(error, phase: "test")
            #expect(result.code == expectedCode, "case \(error) produced \(result.code.rawValue)")
            #expect(!result.stderr.isEmpty)
        }
    }

    @Test("non-LSPClientError falls through to the sourcekit_lsp_error catch-all")
    func unknownErrorCatchAll() {
        struct SomethingElse: Error {}
        let result = RequestProcessor.diagnoseLSPError(SomethingElse(), phase: "references")
        #expect(result.code == .sourcekitLspError)
        #expect(result.stderr.contains("references"))
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
