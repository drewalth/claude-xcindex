import Foundation
import LanguageServerProtocol
import LanguageServerProtocolTransport

// MARK: - LSPClient
//
// Spawns sourcekit-lsp as a subprocess and wraps the JSON-RPC connection.
// Scope of this file (v1.1 steps 4-5): discovery, spawn, initialize /
// initialized handshake, graceful shutdown. Reference queries and
// reconciliation wiring land in later steps.
//
// The wire protocol is handled by swift-tools-protocols'
// `JSONRPCConnection`; we don't touch Content-Length framing, message
// ID correlation, or server-initiated request routing ourselves. See
// the Eng Review decision (use the official library) in the design doc.

/// An active, initialized sourcekit-lsp subprocess + its JSON-RPC
/// connection. Create via `LSPClient.launch(...)`; tear down via
/// `shutdown()` before process exit.
actor LSPClient {
    private let connection: JSONRPCConnection
    private let process: Process
    private let capabilities: ServerCapabilities

    private enum State {
        case running
        case shuttingDown
        case terminated
    }
    private var state: State = .running

    // sourcekit-lsp owns the open-document state once notified; re-sending
    // didOpen for the same URI in-process triggers "document already open"
    // errors from some server builds and wastes round-trips regardless.
    private var openedDocuments: Set<DocumentURI> = []

    /// Server capabilities advertised in the initialize response.
    /// Used by the doctor command + reconciliation path to decide
    /// which semantic queries the live server supports.
    var serverCapabilities: ServerCapabilities { capabilities }

    private init(connection: JSONRPCConnection, process: Process, capabilities: ServerCapabilities) {
        self.connection = connection
        self.process = process
        self.capabilities = capabilities
    }

    // MARK: - Discovery

    /// Locate the `sourcekit-lsp` binary. Priority order:
    ///  1. `SOURCEKIT_LSP_PATH` env var override.
    ///  2. `xcrun --find sourcekit-lsp` (Xcode toolchain).
    ///  3. `which sourcekit-lsp` (PATH).
    static func discover() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["SOURCEKIT_LSP_PATH"],
           !override.isEmpty {
            guard FileManager.default.fileExists(atPath: override) else {
                throw LSPClientError.binaryNotFound
            }
            // Explicit exec-bit check — Process.run on a non-executable
            // path surfaces a generic POSIX error; fail fast with a
            // specific taxonomy instead.
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw LSPClientError.binaryNotExecutable(path: override)
            }
            return URL(fileURLWithPath: override)
        }

        if let xcrunPath = runCommand("/usr/bin/xcrun", args: ["--find", "sourcekit-lsp"]),
           let trimmed = xcrunPath.components(separatedBy: .newlines).first.map({ $0.trimmingCharacters(in: .whitespaces) }),
           !trimmed.isEmpty,
           FileManager.default.fileExists(atPath: trimmed) {
            return URL(fileURLWithPath: trimmed)
        }

        if let whichPath = runCommand("/usr/bin/env", args: ["which", "sourcekit-lsp"]),
           let trimmed = whichPath.components(separatedBy: .newlines).first.map({ $0.trimmingCharacters(in: .whitespaces) }),
           !trimmed.isEmpty,
           FileManager.default.fileExists(atPath: trimmed) {
            return URL(fileURLWithPath: trimmed)
        }

        throw LSPClientError.binaryNotFound
    }

    // MARK: - Lifecycle

    /// Spawn sourcekit-lsp, run the initialize handshake, and return a
    /// ready-to-use client. Caller owns the `shutdown()` call.
    ///
    /// - Parameters:
    ///   - workspaceRoot: the project root URL. Passed to sourcekit-lsp
    ///     as a WorkspaceFolder. For .xcodeproj projects without a
    ///     `compile_commands.json` bridge this will still succeed, but
    ///     subsequent semantic queries may return empty responses —
    ///     that case is handled at the query layer.
    ///   - initializeTimeout: seconds to wait for the server's
    ///     initialize response before treating the spawn as failed.
    static func launch(
        workspaceRoot: URL,
        binaryOverride: URL? = nil,
        initializeTimeout: TimeInterval = 10
    ) async throws -> LSPClient {
        let executable = try binaryOverride ?? discover()

        // JSONRPCConnection.start needs a MessageHandler for
        // server-initiated requests (progress, registerCapability,
        // configuration). We route those through a tiny no-op handler
        // per design Decision 1 + Reviewer Concerns.
        let handler = NoopMessageHandler()

        let (connection, process) = try JSONRPCConnection.start(
            executable: executable,
            arguments: [],
            name: "sourcekit-lsp",
            protocol: MessageRegistry(
                requests: builtinRequests,
                notifications: builtinNotifications
            ),
            stderrLoggingCategory: "xcindex-lsp",
            client: handler,
            terminationHandler: { _ in
                // Termination handler fires asynchronously; `close()`
                // is already called internally. Nothing for us to do.
            }
        )

        // Initialize handshake. Minimal client capabilities — we only
        // use references; omit completion, hover, diagnostics, etc.
        let initRequest = InitializeRequest(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            rootPath: nil,
            rootURI: DocumentURI(workspaceRoot),
            initializationOptions: nil,
            capabilities: ClientCapabilities(
                workspace: nil,
                textDocument: TextDocumentClientCapabilities(
                    references: .init()
                ),
                window: nil,
                general: nil,
                experimental: nil
            ),
            trace: .off,
            workspaceFolders: [WorkspaceFolder(uri: DocumentURI(workspaceRoot))]
        )

        // Track PID for atexit fallback before we await anything that
        // could fail — if the parent dies between now and the handshake,
        // atexit still finds and SIGTERMs this child.
        xcindexTrackChildPID(process.processIdentifier)

        let initResult: InitializeResult
        do {
            initResult = try await sendAndRaceTimeout(
                connection: connection,
                request: initRequest,
                timeout: initializeTimeout,
                timeoutError: LSPClientError.initializeTimeout
            )
        } catch {
            // Best-effort cleanup if initialize failed.
            connection.close()
            if process.isRunning { process.terminate() }
            xcindexUntrackChildPID(process.processIdentifier)
            throw error
        }

        // Required post-initialize notification.
        connection.send(InitializedNotification())

        return LSPClient(
            connection: connection,
            process: process,
            capabilities: initResult.capabilities
        )
    }

    // MARK: - References query

    /// Query sourcekit-lsp for every reference to the symbol declared
    /// at `position` inside `fileURL`. Opens the file first (required
    /// for the server to parse and index it), then issues
    /// `textDocument/references`. Returns an empty array if the
    /// server cannot answer (e.g. the project lacks a
    /// `compile_commands.json` bridge for .xcodeproj sources).
    ///
    /// Paths returned in each Location are passed through as-is;
    /// callers are responsible for realpath-normalizing when
    /// reconciling against indexstore paths.
    ///
    /// - Parameters:
    ///   - fileURL: the file containing the declaration.
    ///   - position: 0-indexed (line, character) of the declaration.
    ///   - timeout: seconds to wait for the references response.
    ///     Beyond the timeout, returns the empty array and logs
    ///     "sourcekit-lsp-timeout" at the call site for tier labeling.
    func references(
        fileURL: URL,
        position: Position,
        timeout: TimeInterval = 10
    ) async throws -> [Location] {
        guard state == .running else {
            throw LSPClientError.notRunning
        }
        guard process.isRunning else {
            state = .terminated
            throw LSPClientError.processTerminated
        }

        // Load the current on-disk contents. Session-edited in-flight
        // buffers are NOT handled here (v1.1 limitation per Reviewer
        // Concerns — tier those files as red-stale in the planner).
        let uri = DocumentURI(fileURL)
        if !openedDocuments.contains(uri) {
            let text: String
            do {
                text = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                throw LSPClientError.fileReadFailed(
                    path: fileURL.path,
                    underlying: error.localizedDescription
                )
            }
            let language = Self.inferLanguage(fileURL: fileURL)
            connection.send(DidOpenTextDocumentNotification(
                textDocument: TextDocumentItem(
                    uri: uri,
                    language: language,
                    version: 0,
                    text: text
                )
            ))
            openedDocuments.insert(uri)
        }

        let request = ReferencesRequest(
            textDocument: TextDocumentIdentifier(uri),
            position: position,
            context: ReferencesContext(includeDeclaration: true)
        )

        return try await Self.sendAndRaceTimeout(
            connection: connection,
            request: request,
            timeout: timeout,
            timeoutError: LSPClientError.referencesTimeout,
            wrapResponseError: { err in
                LSPClientError.protocolError("\(err.code.rawValue): \(err.message)")
            }
        )
    }

    /// Send `request` via `connection` and race the reply against a
    /// timer. Whichever completes first wins; the loser is ignored.
    ///
    /// We cannot put this inside a `withThrowingTaskGroup`: the
    /// request callback runs through `JSONRPCConnection.send`, which
    /// is not cancellation-aware, so the child task would hang
    /// forever when the timeout fires and the group tried to unwind.
    /// A one-shot guard arbitrates which resumption (reply or
    /// timeout) actually fulfills the continuation.
    static func sendAndRaceTimeout<Request: RequestType>(
        connection: JSONRPCConnection,
        request: Request,
        timeout: TimeInterval,
        timeoutError: LSPClientError,
        wrapResponseError: @escaping @Sendable (ResponseError) -> Error = { $0 }
    ) async throws -> Request.Response {
        let guardFlag = OneshotFlag()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Request.Response, Error>) in
            _ = connection.send(request) { result in
                guard guardFlag.trySet() else { return }
                switch result {
                case .success(let value):
                    cont.resume(returning: value)
                case .failure(let err):
                    cont.resume(throwing: wrapResponseError(err))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard guardFlag.trySet() else { return }
                cont.resume(throwing: timeoutError)
            }
        }
    }

    private static func inferLanguage(fileURL: URL) -> Language {
        switch fileURL.pathExtension.lowercased() {
        case "swift": return .swift
        case "m", "mm": return .objective_c
        case "h", "hpp", "hh": return .c
        case "c": return .c
        case "cpp", "cxx", "cc": return .cpp
        default: return .swift
        }
    }

    /// Send `shutdown` + `exit` and wait briefly for the process to
    /// terminate. Idempotent: a second call after teardown is a no-op.
    /// The shutdown request itself is timeout-bounded so a wedged
    /// server can't keep us blocked here — we'll still fall through
    /// to SIGTERM/SIGKILL escalation below.
    func shutdown() async {
        guard state == .running else { return }
        state = .shuttingDown

        _ = try? await Self.sendAndRaceTimeout(
            connection: connection,
            request: ShutdownRequest(),
            timeout: 0.5,
            timeoutError: LSPClientError.notRunning
        )
        connection.send(ExitNotification())
        connection.close()

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning { process.terminate() }

        // SIGTERM may be ignored by a wedged sourcekit-lsp; give it a
        // brief grace window, then SIGKILL rather than leak the child.
        let killDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < killDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            FileHandle.standardError.write(Data(
                "xcindex-lsp: sourcekit-lsp unresponsive to SIGTERM; escalating to SIGKILL (pid \(process.processIdentifier))\n".utf8
            ))
            kill(process.processIdentifier, SIGKILL)
        }

        xcindexUntrackChildPID(process.processIdentifier)
        openedDocuments.removeAll()
        state = .terminated
    }
}

// MARK: - OneshotFlag
//
// Trivially-Sendable atomic "set-once" flag. Used to arbitrate races
// between a JSON-RPC reply callback and a timeout task — the first
// caller to `trySet()` proceeds; the loser no-ops.

final class OneshotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSet else { return false }
        isSet = true
        return true
    }
}

// MARK: - No-op message handler
//
// sourcekit-lsp sends server-initiated requests we don't handle
// meaningfully: window/workDoneProgress/create, client/registerCapability,
// workspace/configuration. We reply with the default success payload
// so the server doesn't log errors / stall. Any unhandled message type
// flows through the library's default (returning methodNotFound).

final class NoopMessageHandler: MessageHandler, Sendable {
    func handle(_ notification: some NotificationType) {
        // Ignore all server-to-client notifications for v1.1 scope.
    }

    func handle<Request: RequestType>(
        _ request: Request,
        id: RequestID,
        reply: @Sendable @escaping (LSPResult<Request.Response>) -> Void
    ) {
        // Return a default-constructed success response where the
        // response type allows it; otherwise fall through to methodNotFound.
        // For the common sourcekit-lsp server-initiated requests
        // (WorkDoneProgressCreateRequest, RegisterCapabilityRequest,
        // ConfigurationRequest) the Response type is `VoidResponse` or
        // an array we can default.
        if Request.Response.self == VoidResponse.self {
            // Type equality check above makes this runtime-safe; Swift
            // generics can't propagate that equality to the cast site.
            reply(.success(VoidResponse() as! Request.Response))
        } else {
            reply(.failure(.methodNotFound(Request.method)))
        }
    }
}

// MARK: - Request / notification registries
//
// MessageRegistry is required by JSONRPCConnection.init — it enumerates
// the request + notification types this connection can *receive* from
// the server. For a client-side connection, that's the set of
// server-initiated requests. Keep this list focused on what sourcekit-lsp
// actually sends, not the full LSP vocabulary.

private let builtinRequests: [_RequestType.Type] = [
    // Server-initiated requests we expect during initialization and
    // workspace setup. NoopMessageHandler short-circuits all of them.
    // Intentionally narrow; extend as we discover more server asks.
]

private let builtinNotifications: [NotificationType.Type] = [
    // Server-initiated notifications we expect and can safely ignore.
]

// MARK: - Errors

enum LSPClientError: LocalizedError, Equatable {
    case binaryNotFound
    case binaryNotExecutable(path: String)
    case initializeTimeout
    case referencesTimeout
    case notRunning
    case processTerminated
    case fileReadFailed(path: String, underlying: String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "sourcekit-lsp not found. Set SOURCEKIT_LSP_PATH, install the Swift toolchain, or run xcindex-doctor for remediation."
        case .binaryNotExecutable(let path):
            return "SOURCEKIT_LSP_PATH points at \(path), but that file is not executable. `chmod +x` it or pick a different binary."
        case .initializeTimeout:
            return "sourcekit-lsp did not respond to initialize within the deadline."
        case .referencesTimeout:
            return "sourcekit-lsp did not respond to textDocument/references within the deadline."
        case .notRunning:
            return "sourcekit-lsp client has been shut down; cannot issue new requests."
        case .processTerminated:
            return "sourcekit-lsp child process has exited; the cached client is stale."
        case .fileReadFailed(let path, let underlying):
            return "Failed to read \(path) for textDocument/didOpen: \(underlying)"
        case .protocolError(let detail):
            return "sourcekit-lsp returned a protocol error: \(detail)"
        }
    }
}

// MARK: - Child-PID registry for atexit fallback
//
// Normal teardown runs through `LSPClient.shutdown()`. If the xcindex
// process exits through a path that skips that (uncaught error, abrupt
// EOF handled before the shutdown call, atexit from library code), the
// sourcekit-lsp children would otherwise be orphaned. The atexit hook
// installed in main.swift SIGTERMs everything still in this set.

private nonisolated(unsafe) var _xcindexTrackedChildPIDs: Set<Int32> = []
private let _xcindexTrackedChildPIDsLock = NSLock()

func xcindexTrackChildPID(_ pid: Int32) {
    _xcindexTrackedChildPIDsLock.lock()
    _xcindexTrackedChildPIDs.insert(pid)
    _xcindexTrackedChildPIDsLock.unlock()
}

func xcindexUntrackChildPID(_ pid: Int32) {
    _xcindexTrackedChildPIDsLock.lock()
    _xcindexTrackedChildPIDs.remove(pid)
    _xcindexTrackedChildPIDsLock.unlock()
}

func xcindexTerminateTrackedChildren() {
    _xcindexTrackedChildPIDsLock.lock()
    let pids = _xcindexTrackedChildPIDs
    _xcindexTrackedChildPIDs.removeAll()
    _xcindexTrackedChildPIDsLock.unlock()
    for pid in pids {
        kill(pid, SIGTERM)
    }
}
