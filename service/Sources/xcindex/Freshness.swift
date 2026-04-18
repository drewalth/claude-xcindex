import CryptoKit
import Foundation

// Session-edited-file state shared with the PostToolUse + SessionStart bash hooks.
//
// Path derivation MUST match hooks/session-start.sh and hooks/post-edit.sh
// byte-for-byte: $TMPDIR/xcindex-edited-<sha1(cwd) first 12 chars>.txt.
// CLAUDE_PROJECT_DIR overrides cwd.
enum Freshness {
    static func stateFilePath() -> String {
        let env = ProcessInfo.processInfo.environment
        let cwd = env["CLAUDE_PROJECT_DIR"]
            ?? FileManager.default.currentDirectoryPath
        let tmp = (env["TMPDIR"] ?? "/tmp").trimmingTrailingSlash()
        let digest = Insecure.SHA1.hash(data: Data(cwd.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        return "\(tmp)/xcindex-edited-\(hash).txt"
    }

    static func getEditedFiles() -> Set<String> {
        let path = stateFilePath()
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return Set(
            contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    static func staleNote(involvedPaths: [String]) -> String? {
        let edited = getEditedFiles()
        let stale = involvedPaths.filter { edited.contains($0) }
        guard !stale.isEmpty else { return nil }
        let names = stale.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        let verb = stale.count == 1 ? "was" : "were"
        return "Note: \(names) \(verb) edited this session after the index was built; results may be stale."
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
