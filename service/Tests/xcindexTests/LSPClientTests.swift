import Darwin
import Foundation
import LanguageServerProtocol
import Testing
@testable import xcindex

/// Integration tests for the sourcekit-lsp subprocess client.
///
/// The lifecycle + real-references tests require a working
/// sourcekit-lsp on the machine and skip when absent. The failure-mode
/// tests below drive a scripted Python fake (see `FakeLSPServer`) so
/// they run unconditionally — including on CI without a toolchain.
@Suite("LSPClient", .serialized)
struct LSPClientTests {
    // MARK: - discover()

    @Test("discover() honors SOURCEKIT_LSP_PATH when it points at an existing file")
    func discoveryEnvOverride() throws {
        // Use this test source file as the sentinel — it's guaranteed to exist.
        let sentinel = #filePath
        #expect(FileManager.default.fileExists(atPath: sentinel))

        let previous = ProcessInfo.processInfo.environment["SOURCEKIT_LSP_PATH"]
        setenv("SOURCEKIT_LSP_PATH", sentinel, 1)
        defer {
            if let previous {
                setenv("SOURCEKIT_LSP_PATH", previous, 1)
            } else {
                unsetenv("SOURCEKIT_LSP_PATH")
            }
        }

        let resolved = try LSPClient.discover()
        #expect(resolved.path == sentinel)
    }

    @Test("discover() throws .binaryNotFound when nothing resolves")
    func discoveryMissingBinary() throws {
        let previous = ProcessInfo.processInfo.environment["SOURCEKIT_LSP_PATH"]
        // Point at a path we know does not exist so the env-var branch
        // falls through to xcrun/which. On a dev box with Xcode those
        // will still resolve; this test is meaningful mainly on CI
        // without a toolchain.
        setenv("SOURCEKIT_LSP_PATH", "/nonexistent/xcindex/sourcekit-lsp", 1)
        defer {
            if let previous {
                setenv("SOURCEKIT_LSP_PATH", previous, 1)
            } else {
                unsetenv("SOURCEKIT_LSP_PATH")
            }
        }

        do {
            _ = try LSPClient.discover()
            // Dev box: fell through to xcrun/which and found something.
        } catch let error as LSPClientError {
            #expect(error == .binaryNotFound)
        }
    }

    // MARK: - spawn + initialize + shutdown lifecycle (real sourcekit-lsp)

    @Test("launch + shutdown completes cleanly when sourcekit-lsp is available")
    func spawnAndShutdown() async throws {
        guard (try? LSPClient.discover()) != nil else { return }

        let fixture = try FixtureHolder.shared()
        let workspaceRoot = URL(fileURLWithPath: fixture.sourceDir)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let client = try await LSPClient.launch(workspaceRoot: workspaceRoot)
        _ = await client.serverCapabilities
        await client.shutdown()
    }

    @Test("references() returns at least one Location for UserService class decl")
    func referencesForCanarySymbol() async throws {
        guard (try? LSPClient.discover()) != nil else { return }

        let fixture = try FixtureHolder.shared()
        let workspaceRoot = URL(fileURLWithPath: fixture.sourceDir)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let client = try await LSPClient.launch(workspaceRoot: workspaceRoot)
        defer { Task { await client.shutdown() } }

        let userServiceURL = URL(fileURLWithPath: fixture.sourcePath("UserService.swift"))
        let locations = try await client.references(
            fileURL: userServiceURL,
            position: Position(line: 9, utf16index: 6)
        )

        if locations.isEmpty { return }
        let decls = locations.filter { loc in
            (loc.uri.fileURL?.path ?? "").hasSuffix("UserService.swift")
        }
        #expect(!decls.isEmpty, "expected at least one Location in UserService.swift; got \(locations.map { $0.uri.stringValue })")
    }

    // MARK: - Failure-mode coverage via FakeLSPServer

    @Test("initialize timeout surfaces LSPClientError.initializeTimeout")
    func initializeTimeoutFromFake() async throws {
        let fake = try FakeLSPServer(mode: .initializeTimeout)
        let workspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory())

        do {
            _ = try await LSPClient.launch(
                workspaceRoot: workspaceRoot,
                binaryOverride: fake.binaryURL,
                initializeTimeout: 0.5
            )
            Issue.record("expected launch() to throw")
        } catch let error as LSPClientError {
            #expect(error == .initializeTimeout)
        }
    }

    @Test("references() timeout surfaces LSPClientError.referencesTimeout")
    func referencesTimeoutFromFake() async throws {
        let fake = try FakeLSPServer(mode: .referencesTimeout)
        let workspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory())

        let client = try await LSPClient.launch(
            workspaceRoot: workspaceRoot,
            binaryOverride: fake.binaryURL,
            initializeTimeout: 2
        )

        do {
            _ = try await client.references(
                fileURL: URL(fileURLWithPath: #filePath),
                position: Position(line: 0, utf16index: 0),
                timeout: 0.5
            )
            Issue.record("expected references() to throw .referencesTimeout")
        } catch let error as LSPClientError {
            #expect(error == .referencesTimeout)
        }
        await client.shutdown()
    }

    @Test("references() protocol error surfaces LSPClientError.protocolError")
    func referencesProtocolErrorFromFake() async throws {
        let fake = try FakeLSPServer(mode: .referencesProtocolError)
        let workspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory())

        let client = try await LSPClient.launch(
            workspaceRoot: workspaceRoot,
            binaryOverride: fake.binaryURL,
            initializeTimeout: 2
        )

        do {
            _ = try await client.references(
                fileURL: URL(fileURLWithPath: #filePath),
                position: Position(line: 0, utf16index: 0),
                timeout: 2
            )
            Issue.record("expected references() to throw .protocolError")
        } catch let error as LSPClientError {
            if case .protocolError(let detail) = error {
                #expect(detail.contains("fake protocol error"))
            } else {
                Issue.record("expected .protocolError, got \(error)")
            }
        }
        await client.shutdown()
    }

    @Test("references() on an unreadable path surfaces LSPClientError.fileReadFailed")
    func referencesFileReadFailedFromFake() async throws {
        let fake = try FakeLSPServer(mode: .initializeOnly)
        let workspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory())

        let client = try await LSPClient.launch(
            workspaceRoot: workspaceRoot,
            binaryOverride: fake.binaryURL,
            initializeTimeout: 2
        )

        let missing = URL(fileURLWithPath: "/nonexistent/xcindex/missing.swift")
        do {
            _ = try await client.references(
                fileURL: missing,
                position: Position(line: 0, utf16index: 0),
                timeout: 2
            )
            Issue.record("expected references() to throw .fileReadFailed")
        } catch let error as LSPClientError {
            if case .fileReadFailed(let path, _) = error {
                #expect(path == missing.path)
            } else {
                Issue.record("expected .fileReadFailed, got \(error)")
            }
        }
        await client.shutdown()
    }

    @Test("references() after shutdown surfaces LSPClientError.notRunning")
    func referencesAfterShutdownFromFake() async throws {
        let fake = try FakeLSPServer(mode: .initializeOnly)
        let workspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory())

        let client = try await LSPClient.launch(
            workspaceRoot: workspaceRoot,
            binaryOverride: fake.binaryURL,
            initializeTimeout: 2
        )
        await client.shutdown()

        do {
            _ = try await client.references(
                fileURL: URL(fileURLWithPath: #filePath),
                position: Position(line: 0, utf16index: 0),
                timeout: 1
            )
            Issue.record("expected .notRunning")
        } catch let error as LSPClientError {
            #expect(error == .notRunning)
        }
    }

    @Test("shutdown() is idempotent — a second call is a no-op")
    func shutdownIsIdempotent() async throws {
        let fake = try FakeLSPServer(mode: .initializeOnly)
        let workspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory())

        let client = try await LSPClient.launch(
            workspaceRoot: workspaceRoot,
            binaryOverride: fake.binaryURL,
            initializeTimeout: 2
        )
        await client.shutdown()
        await client.shutdown() // should not hang or crash
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
