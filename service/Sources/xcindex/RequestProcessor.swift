import Foundation
import LanguageServerProtocol

/// Routes decoded requests to the appropriate query function.
///
/// Keeps an open `IndexQuerier` cached by store path so repeated queries
/// against the same project don't re-open the database each time. For
/// `planRename` requests also keeps an LSP subprocess cached per
/// (realpath-normalized) workspace root so the sourcekit-lsp spawn +
/// initialize handshake is paid once per session.
actor RequestProcessor {
    private var querierCache: [String: IndexQuerier] = [:]
    private var lspClientCache: [String: LSPClient] = [:]

    func handle(_ request: Request) async -> Response {
        switch request.op {
        case "findRefs":
            return handleFindRefs(request)
        case "findSymbol":
            return handleFindSymbol(request)
        case "findDefinition":
            return handleFindDefinition(request)
        case "findOverrides":
            return handleFindOverrides(request)
        case "findConformances":
            return handleFindConformances(request)
        case "blastRadius":
            return handleBlastRadius(request)
        case "status":
            return handleStatus(request)
        case "planRename":
            return await handlePlanRename(request)
        default:
            return Response(error: "Unknown op '\(request.op)'")
        }
    }

    // MARK: - findRefs

    private func handleFindRefs(_ request: Request) -> Response {
        guard let symbolName = request.symbolName, !symbolName.isEmpty else {
            return Response(error: "findRefs requires 'symbolName'")
        }
        do {
            let querier = try makeQuerier(request)
            return Response(occurrences: querier.findRefs(symbolName: symbolName))
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - findSymbol

    private func handleFindSymbol(_ request: Request) -> Response {
        guard let symbolName = request.symbolName, !symbolName.isEmpty else {
            return Response(error: "findSymbol requires 'symbolName'")
        }
        do {
            let querier = try makeQuerier(request)
            return Response(symbols: querier.findSymbol(symbolName: symbolName))
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - findDefinition

    private func handleFindDefinition(_ request: Request) -> Response {
        guard let usr = request.usr, !usr.isEmpty else {
            return Response(error: "findDefinition requires 'usr'")
        }
        do {
            let querier = try makeQuerier(request)
            if let occ = querier.findDefinition(usr: usr) {
                return Response(occurrences: [occ])
            } else {
                return Response(occurrences: [])
            }
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - findOverrides

    private func handleFindOverrides(_ request: Request) -> Response {
        guard let usr = request.usr, !usr.isEmpty else {
            return Response(error: "findOverrides requires 'usr'")
        }
        do {
            let querier = try makeQuerier(request)
            return Response(occurrences: querier.findOverrides(usr: usr))
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - findConformances

    private func handleFindConformances(_ request: Request) -> Response {
        guard let usr = request.usr, !usr.isEmpty else {
            return Response(error: "findConformances requires 'usr'")
        }
        do {
            let querier = try makeQuerier(request)
            return Response(occurrences: querier.findConformances(usr: usr))
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - blastRadius

    private func handleBlastRadius(_ request: Request) -> Response {
        guard let filePath = request.filePath, !filePath.isEmpty else {
            return Response(error: "blastRadius requires 'filePath'")
        }
        do {
            let querier = try makeQuerier(request)
            return Response(blastRadius: querier.blastRadius(filePath: filePath))
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    // MARK: - status

    private func handleStatus(_ request: Request) -> Response {
        do {
            let storePath = try DerivedDataLocator.indexStorePath(
                projectPath: request.projectPath,
                indexStorePath: request.indexStorePath
            )
            let querier = try querierForStore(storePath)
            return Response(status: querier.status(storePath: storePath))
        } catch {
            // Status should be informative even when the index doesn't exist
            return Response(status: StatusResult(
                indexStorePath: request.indexStorePath ?? "(unknown)",
                indexMtime: nil,
                staleFileCount: 0,
                staleFiles: [],
                summary: error.localizedDescription
            ))
        }
    }

    // MARK: - planRename

    private func handlePlanRename(_ request: Request) async -> Response {
        guard let usr = request.usr, !usr.isEmpty else {
            return Response(error: "planRename requires 'usr'")
        }
        guard let newName = request.newName, !newName.isEmpty else {
            return Response(error: "planRename requires 'newName'")
        }
        do {
            let querier = try makeQuerier(request)
            let planner = RenamePlanner(querier: querier)
            let indexstorePlan = planner.plan(usr: usr, newName: newName)

            // Refusals and empty plans skip LSP — reconciliation adds
            // nothing when there's nothing to verify.
            if indexstorePlan.refusal != nil || indexstorePlan.ranges.isEmpty {
                return Response(renamePlan: indexstorePlan)
            }

            let reconciled = await reconcileWithLSP(
                plan: indexstorePlan,
                usr: usr,
                request: request,
                querier: querier
            )
            return Response(renamePlan: reconciled)
        } catch {
            return Response(error: error.localizedDescription)
        }
    }

    /// Resolves the workspace, lazily spawns sourcekit-lsp if needed,
    /// and reconciles the indexstore-only plan with the server's
    /// `textDocument/references` response. Every failure mode adds a
    /// specific diagnostic warning so callers can remediate rather
    /// than guess why the plan wasn't LSP-verified. See
    /// `diagnoseLSPError(_:)` for the full taxonomy.
    private func reconcileWithLSP(
        plan: RenamePlan,
        usr: String,
        request: Request,
        querier: IndexQuerier
    ) async -> RenamePlan {
        guard let def = querier.findDefinition(usr: usr) else {
            return plan
        }

        guard let workspaceRoot = deriveWorkspaceRoot(request: request) else {
            return withWarnings(
                RenamePlanner.reconcile(plan, with: [], lspConsulted: false),
                appending: ["workspace_root_unresolved"]
            )
        }

        let diagnostics = WorkspaceDiagnostics(root: workspaceRoot)
        var projectWarnings: [String] = []
        if diagnostics.isXcodeProject, !diagnostics.hasBuildServerBridge {
            projectWarnings.append("compile_commands_missing")
        }

        let client: LSPClient
        do {
            client = try await lspClient(for: workspaceRoot)
        } catch {
            let (code, stderrLine) = Self.diagnoseLSPError(error, phase: "launch")
            FileHandle.standardError.write(Data(
                "xcindex-lsp: skipping reconciliation — \(stderrLine)\n".utf8
            ))
            return withWarnings(
                RenamePlanner.reconcile(plan, with: [], lspConsulted: false),
                appending: projectWarnings + [code]
            )
        }

        do {
            // IndexStoreDB is 1-indexed UTF-8; LSP is 0-indexed UTF-16.
            // The -1 alignment only holds exactly for ASCII identifiers;
            // non-ASCII names are already flagged yellow in the planner.
            let position = Position(line: def.line - 1, utf16index: def.column - 1)
            let fileURL = URL(fileURLWithPath: def.path)
            let locations = try await client.references(fileURL: fileURL, position: position)

            let lspRefs = locations.compactMap { loc -> LSPRefLocation? in
                guard let path = loc.uri.fileURL?.path else { return nil }
                return LSPRefLocation(
                    path: path,
                    line: loc.range.lowerBound.line,
                    character: loc.range.lowerBound.utf16index,
                    endLine: loc.range.upperBound.line,
                    endCharacter: loc.range.upperBound.utf16index
                )
            }
            var extras = projectWarnings
            // Empty-from-Xcode-project is the classic "no build context"
            // case — point the user at xcode-build-server.
            if lspRefs.isEmpty, diagnostics.isXcodeProject, !diagnostics.hasBuildServerBridge {
                extras.append("sourcekit_lsp_needs_compile_commands")
            }
            let reconciled = RenamePlanner.reconcile(plan, with: lspRefs, lspConsulted: true)
            return withWarnings(reconciled, appending: extras)
        } catch {
            let (code, stderrLine) = Self.diagnoseLSPError(error, phase: "references")
            FileHandle.standardError.write(Data(
                "xcindex-lsp: \(stderrLine)\n".utf8
            ))
            return withWarnings(
                RenamePlanner.reconcile(plan, with: [], lspConsulted: false),
                appending: projectWarnings + [code]
            )
        }
    }

    /// Maps an error raised by `LSPClient.launch(...)` or
    /// `LSPClient.references(...)` to:
    ///   * the warning code appended to the plan (one per failure mode)
    ///   * the stderr line written alongside the response so callers
    ///     can correlate the warning to the underlying failure
    ///
    /// Exhaustive over `LSPClientError`; unrecognized errors fall
    /// through to the `sourcekit_lsp_error` catch-all. Adding a new
    /// `LSPClientError` case without handling it here triggers a
    /// compiler warning — keep the taxonomy honest.
    ///
    /// Internal for unit-test coverage of the taxonomy mapping.
    static func diagnoseLSPError(_ error: Error, phase: String) -> (code: String, stderr: String) {
        if let lspError = error as? LSPClientError {
            switch lspError {
            case .binaryNotFound:
                return ("sourcekit_lsp_not_found", "binary not found: \(lspError.localizedDescription)")
            case .binaryNotExecutable(let path):
                return ("sourcekit_lsp_not_found", "binary not executable at \(path)")
            case .initializeTimeout:
                return ("sourcekit_lsp_launch_failed", "initialize timed out during \(phase)")
            case .referencesTimeout:
                return ("sourcekit_lsp_timeout", "references query timed out")
            case .notRunning:
                return ("sourcekit_lsp_not_running", "client already shut down during \(phase)")
            case .processTerminated:
                return ("sourcekit_lsp_process_terminated", "child process exited during \(phase)")
            case .fileReadFailed(let path, let underlying):
                return ("lsp_file_read_failed", "file read failed for \(path) during \(phase): \(underlying)")
            case .protocolError(let detail):
                return ("sourcekit_lsp_protocol_error", "protocol error during \(phase): \(detail)")
            }
        }
        return (
            "sourcekit_lsp_error",
            "unexpected error during \(phase) (\(type(of: error))): \(error.localizedDescription)"
        )
    }

    /// Return a copy of `plan` with `extras` appended to `warnings`,
    /// preserving order and deduping against existing entries.
    private func withWarnings(_ plan: RenamePlan, appending extras: [String]) -> RenamePlan {
        guard !extras.isEmpty else { return plan }
        var merged = plan.warnings
        for warning in extras where !merged.contains(warning) {
            merged.append(warning)
        }
        return RenamePlan(
            usr: plan.usr,
            oldName: plan.oldName,
            newName: plan.newName,
            generatedAt: plan.generatedAt,
            indexFreshness: plan.indexFreshness,
            ranges: plan.ranges,
            summary: plan.summary,
            refusal: plan.refusal,
            warnings: merged
        )
    }

    // MARK: - Helpers

    private func makeQuerier(_ request: Request) throws -> IndexQuerier {
        let storePath = try DerivedDataLocator.indexStorePath(
            projectPath: request.projectPath,
            indexStorePath: request.indexStorePath
        )
        return try querierForStore(storePath)
    }

    private func querierForStore(_ storePath: String) throws -> IndexQuerier {
        if let cached = querierCache[storePath] {
            return cached
        }
        let querier = try IndexQuerier(storePath: storePath)
        querierCache[storePath] = querier
        return querier
    }

    private func lspClient(for workspaceRoot: URL) async throws -> LSPClient {
        let key = (workspaceRoot.path as NSString).resolvingSymlinksInPath
        if let cached = lspClientCache[key] {
            return cached
        }
        let client = try await LSPClient.launch(workspaceRoot: workspaceRoot)
        lspClientCache[key] = client
        return client
    }

    /// Tear down every cached sourcekit-lsp subprocess. Called on
    /// normal EOF and from the SIGINT/SIGTERM handlers in main.swift —
    /// idempotent per `LSPClient.shutdown()`.
    func shutdownAll() async {
        let clients = Array(lspClientCache.values)
        lspClientCache.removeAll()
        for client in clients {
            await client.shutdown()
        }
    }

    /// Pick a sensible workspace root to hand to sourcekit-lsp.
    ///
    /// Priority:
    ///  1. `projectPath` if given: parent of .xcodeproj/.xcworkspace,
    ///     or the directory itself for SPM packages.
    ///  2. Otherwise walk up from `indexStorePath` looking for a
    ///     `Package.swift` or a sibling .xcodeproj/.xcworkspace — a
    ///     best-effort fallback for callers that pass only the store.
    private func deriveWorkspaceRoot(request: Request) -> URL? {
        if let projectPath = request.projectPath, !projectPath.isEmpty {
            let url = URL(fileURLWithPath: projectPath)
            let ext = url.pathExtension
            if ext == "xcodeproj" || ext == "xcworkspace" {
                return url.deletingLastPathComponent()
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir),
               isDir.boolValue {
                return url
            }
            return url.deletingLastPathComponent()
        }

        if let indexStorePath = request.indexStorePath, !indexStorePath.isEmpty {
            var url = URL(fileURLWithPath: indexStorePath)
            for _ in 0 ..< 10 {
                url = url.deletingLastPathComponent()
                if url.path == "/" { break }
                let pkg = url.appendingPathComponent("Package.swift").path
                if FileManager.default.fileExists(atPath: pkg) {
                    return url
                }
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                   contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") })
                {
                    return url
                }
            }
        }
        return nil
    }
}

// MARK: - Workspace diagnostics

/// Classifies a workspace root as SwiftPM vs. Xcode-project and checks
/// for the build-context bridge that sourcekit-lsp needs to answer
/// semantic queries. A `.xcodeproj`/`.xcworkspace` without a
/// `compile_commands.json` or `buildServer.json` at the root is the
/// canonical "LSP will return empty" configuration — we surface it as
/// a `compile_commands_missing` warning so users can install
/// xcode-build-server instead of wondering why ranges aren't verified.
struct WorkspaceDiagnostics {
    let isXcodeProject: Bool
    let hasBuildServerBridge: Bool

    init(root: URL) {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []

        let hasPackageSwift = contents.contains("Package.swift")
        let hasXcodeWorkspace = contents.contains(where: {
            $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace")
        })
        // Treat mixed repos (both Package.swift *and* an xcodeproj) as
        // SPM — the package build is what sourcekit-lsp can resolve
        // without extra setup.
        self.isXcodeProject = hasXcodeWorkspace && !hasPackageSwift

        let bridgeFiles = ["compile_commands.json", "buildServer.json"]
        self.hasBuildServerBridge = bridgeFiles.contains(where: {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        })
    }
}
