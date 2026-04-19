import Foundation
import Testing
@testable import xcindex

/// Covers the `Freshness` module, which is the load-bearing contract
/// shared with `hooks/session-start.sh` and `hooks/post-edit.sh`. If the
/// state-file path derivation drifts, the bash hooks and the Swift binary
/// will read from different files and stale-file annotations will silently
/// stop working.
/// `setenv` mutates process-global state, so these tests must run one at
/// a time. A missing `.serialized` here was a real bug during Phase 2 —
/// parallel tests raced and `staleNote` read from another test's
/// CLAUDE_PROJECT_DIR-derived path.
@Suite("Freshness", .serialized)
struct FreshnessTests {
    // MARK: - stateFilePath

    @Test("stateFilePath uses CLAUDE_PROJECT_DIR when set")
    func stateFilePathHonorsClaudeProjectDir() throws {
        try withEnv(["CLAUDE_PROJECT_DIR": "/tmp/fake-project-a", "TMPDIR": "/tmp/"]) {
            let pathA = Freshness.stateFilePath()
            #expect(pathA.hasPrefix("/tmp/xcindex-edited-"))
            #expect(pathA.hasSuffix(".txt"))

            // Different project dir → different hash → different path.
            setenv("CLAUDE_PROJECT_DIR", "/tmp/fake-project-b", 1)
            let pathB = Freshness.stateFilePath()
            #expect(pathA != pathB)
        }
    }

    @Test("stateFilePath trims trailing slash on TMPDIR")
    func stateFilePathTrimsTmpdir() throws {
        try withEnv(["CLAUDE_PROJECT_DIR": "/tmp/whatever", "TMPDIR": "/tmp/"]) {
            let path = Freshness.stateFilePath()
            #expect(!path.contains("//xcindex-edited-"))
        }
    }

    @Test("stateFilePath hash is exactly 12 hex characters")
    func stateFilePathHashShape() throws {
        try withEnv(["CLAUDE_PROJECT_DIR": "/some/path", "TMPDIR": "/tmp"]) {
            let path = Freshness.stateFilePath()
            // Extract the hash between "xcindex-edited-" and ".txt".
            let name = (path as NSString).lastPathComponent
            #expect(name.hasPrefix("xcindex-edited-"))
            #expect(name.hasSuffix(".txt"))
            let hash = String(
                name
                    .dropFirst("xcindex-edited-".count)
                    .dropLast(".txt".count)
            )
            #expect(hash.count == 12)
            #expect(hash.allSatisfy { $0.isHexDigit })
        }
    }

    // MARK: - getEditedFiles

    @Test("getEditedFiles returns empty set when state file is missing")
    func getEditedFilesMissing() throws {
        try withIsolatedState { _ in
            #expect(Freshness.getEditedFiles().isEmpty)
        }
    }

    @Test("getEditedFiles parses one-path-per-line format")
    func getEditedFilesParses() throws {
        try withIsolatedState { path in
            try "/a/b.swift\n/c/d.swift\n".write(
                toFile: path, atomically: true, encoding: .utf8
            )
            #expect(Freshness.getEditedFiles() == ["/a/b.swift", "/c/d.swift"])
        }
    }

    @Test("getEditedFiles ignores blank lines and trims whitespace")
    func getEditedFilesTolerates() throws {
        try withIsolatedState { path in
            try "  /a/b.swift  \n\n  \n/c/d.swift\n".write(
                toFile: path, atomically: true, encoding: .utf8
            )
            #expect(Freshness.getEditedFiles() == ["/a/b.swift", "/c/d.swift"])
        }
    }

    // MARK: - staleNote

    @Test("staleNote returns nil when no involved path was edited")
    func staleNoteClean() throws {
        try withIsolatedState { path in
            try "/edited.swift\n".write(
                toFile: path, atomically: true, encoding: .utf8
            )
            #expect(Freshness.staleNote(involvedPaths: ["/not-edited.swift"]) == nil)
        }
    }

    @Test("staleNote names a single edited file using singular verb")
    func staleNoteSingular() throws {
        try withIsolatedState { path in
            try "/edited.swift\n".write(
                toFile: path, atomically: true, encoding: .utf8
            )
            let note = Freshness.staleNote(involvedPaths: ["/edited.swift"])
            #expect(note == "Note: edited.swift was edited this session after the index was built; results may be stale.")
        }
    }

    @Test("staleNote names multiple edited files using plural verb")
    func staleNotePlural() throws {
        try withIsolatedState { path in
            try "/a.swift\n/b.swift\n".write(
                toFile: path, atomically: true, encoding: .utf8
            )
            let note = Freshness.staleNote(involvedPaths: ["/a.swift", "/b.swift"])
            #expect(note?.contains("a.swift, b.swift") == true)
            #expect(note?.contains(" were edited ") == true)
        }
    }
}

// MARK: - Test helpers

/// Swap in a unique `CLAUDE_PROJECT_DIR` so the state file lives under
/// an isolated hash per test. Blocks run serially within one test, so
/// env mutation is safe here.
private func withIsolatedState(_ body: (_ statePath: String) throws -> Void) throws {
    let unique = "/xcindex-test-\(UUID().uuidString)"
    try withEnv(["CLAUDE_PROJECT_DIR": unique]) {
        let path = Freshness.stateFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }
}

private func withEnv(_ env: [String: String], _ body: () throws -> Void) throws {
    let previous = env.keys.reduce(into: [String: String?]()) { acc, key in
        acc[key] = ProcessInfo.processInfo.environment[key]
    }
    for (key, value) in env {
        setenv(key, value, 1)
    }
    defer {
        for (key, old) in previous {
            if let old {
                setenv(key, old, 1)
            } else {
                unsetenv(key)
            }
        }
    }
    try body()
}
