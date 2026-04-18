import Foundation
import IndexStoreDB

// MARK: - IndexStoreDB query helpers

/// Wraps IndexStoreDB to run semantic queries against Xcode's pre-built index.
final class IndexQuerier {
    private let db: IndexStoreDB

    /// - Parameter storePath: Path to the `DataStore` directory inside DerivedData.
    init(storePath: String) throws {
        // IndexStoreDB creates its own SQLite cache in `databasePath`.
        // Use a deterministic temp path keyed on the store path so the cache
        // survives multiple invocations without being rebuilt each time.
        let storeKey = storePath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let suffix = String(storeKey.suffix(60))
        let databasePath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("xcindex-db-\(suffix)")

        let library = try loadIndexStoreLibrary()

        self.db = try IndexStoreDB(
            storePath: storePath,
            databasePath: databasePath,
            library: library,
            waitUntilDoneInitializing: true,
            listenToUnitEvents: false
        )
    }

    // MARK: - findRefs

    /// Find all occurrences of a symbol by name.
    ///
    /// Workflow:
    ///  1. Use `canonicalOccurrences(ofName:)` to find exact-name matches and
    ///     collect their USRs.
    ///  2. Fall back to `forEachCanonicalSymbolOccurrence(containing:...)` if no
    ///     exact hits (e.g. operator or partial name given).
    ///  3. For each USR, fetch all occurrences via `occurrences(ofUSR:roles:)`.
    ///  4. Return deduplicated list sorted by file+line.
    func findRefs(symbolName: String) -> [OccurrenceResult] {
        var usrs = Set<String>()

        // Exact-name canonical lookup (fast path)
        let canonical = db.canonicalOccurrences(ofName: symbolName)
        for occ in canonical {
            usrs.insert(occ.symbol.usr)
        }

        // Pattern-match fallback if no exact hits
        if usrs.isEmpty {
            db.forEachCanonicalSymbolOccurrence(
                containing: symbolName,
                anchorStart: false,
                anchorEnd: false,
                subsequence: false,
                ignoreCase: false
            ) { occ in
                if occ.symbol.name == symbolName {
                    usrs.insert(occ.symbol.usr)
                }
                return true // keep iterating
            }
        }

        var seen = Set<String>()
        var results: [OccurrenceResult] = []

        for usr in usrs.sorted() {
            let occurrences = db.occurrences(
                ofUSR: usr,
                roles: [.definition, .declaration, .reference, .call, .read, .write, .overrideOf]
            )
            for occ in occurrences {
                guard !occ.location.isSystem else { continue }
                let key = "\(occ.location.path):\(occ.location.line):\(occ.location.utf8Column)"
                guard seen.insert(key).inserted else { continue }
                results.append(OccurrenceResult(
                    usr: usr,
                    symbolName: occ.symbol.name,
                    path: occ.location.path,
                    line: occ.location.line,
                    column: occ.location.utf8Column,
                    roles: occ.roles.humanReadable
                ))
            }
        }

        return results.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.line != $1.line { return $0.line < $1.line }
            return $0.column < $1.column
        }
    }
}

// MARK: - IndexStoreLibrary loading

/// Loads `libIndexStore.dylib` from the active Xcode installation.
func loadIndexStoreLibrary() throws -> IndexStoreLibrary {
    let candidates: [String?] = [
        xcrunDerivedToolchainPath(),
        xcrunContentsPath().map { $0 + "/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib" },
        xcrunContentsPath().map { $0 + "/SharedFrameworks/IndexStore.framework/Versions/A/IndexStore" },
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
        "/Applications/Xcode.app/Contents/SharedFrameworks/IndexStore.framework/Versions/A/IndexStore",
        "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
    ]

    for path in candidates.compactMap({ $0 }) {
        if FileManager.default.fileExists(atPath: path) {
            return try IndexStoreLibrary(dylibPath: path)
        }
    }
    throw IndexQuerierError.noIndexStoreLibrary
}

/// Use `xcrun --find libIndexStore.dylib` directly.
private func xcrunDerivedToolchainPath() -> String? {
    // xcrun can locate the dylib directly
    return runCommand("/usr/bin/xcrun", args: ["-f", "--show-sdk-path"])
        .flatMap { _ in
            runCommand("/usr/bin/xcrun", args: ["--find", "clang"])
                .map { clang -> String in
                    // clang is at .../usr/bin/clang; libIndexStore is at .../usr/lib/libIndexStore.dylib
                    let url = URL(fileURLWithPath: clang.trimmingCharacters(in: .whitespacesAndNewlines))
                    return url
                        .deletingLastPathComponent()          // bin
                        .deletingLastPathComponent()          // usr
                        .appendingPathComponent("lib/libIndexStore.dylib")
                        .path
                }
        }
}

/// Walk up from the SDK path to find `Xcode.app/Contents/`.
private func xcrunContentsPath() -> String? {
    guard let sdkPath = runCommand("/usr/bin/xcrun", args: ["--show-sdk-path"]) else {
        return nil
    }
    var url = URL(fileURLWithPath: sdkPath.trimmingCharacters(in: .whitespacesAndNewlines))
    while url.pathComponents.count > 1 {
        url = url.deletingLastPathComponent()
        if url.lastPathComponent == "Contents" {
            return url.path
        }
    }
    return nil
}

// MARK: - Process helper

/// Run a command synchronously and return combined stdout, or nil on failure.
func runCommand(_ path: String, args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}

// MARK: - SymbolRole → [String]

extension SymbolRole {
    var humanReadable: [String] {
        var names: [String] = []
        if contains(.definition)        { names.append("definition") }
        if contains(.declaration)       { names.append("declaration") }
        if contains(.reference)         { names.append("reference") }
        if contains(.call)              { names.append("call") }
        if contains(.read)              { names.append("read") }
        if contains(.write)             { names.append("write") }
        if contains(.dynamic)           { names.append("dynamic") }
        if contains(.addressOf)         { names.append("addressOf") }
        if contains(.implicit)          { names.append("implicit") }
        if contains(.overrideOf)        { names.append("overrideOf") }
        if contains(.accessorOf)        { names.append("accessorOf") }
        if contains(.childOf)           { names.append("childOf") }
        if contains(.baseOf)            { names.append("baseOf") }
        if contains(.extendedBy)        { names.append("extendedBy") }
        if contains(.receivedBy)        { names.append("receivedBy") }
        if contains(.calledBy)          { names.append("calledBy") }
        if contains(.containedBy)       { names.append("containedBy") }
        if contains(.specializationOf)  { names.append("specializationOf") }
        return names.isEmpty ? ["unknown"] : names
    }
}

// MARK: - Errors

enum IndexQuerierError: LocalizedError {
    case noIndexStoreLibrary

    var errorDescription: String? {
        switch self {
        case .noIndexStoreLibrary:
            return "Could not locate IndexStore.framework. " +
                   "Ensure Xcode is installed at /Applications/Xcode.app."
        }
    }
}
