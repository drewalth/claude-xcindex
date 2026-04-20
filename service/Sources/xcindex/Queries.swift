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

    // MARK: - occurrences(ofUSR:roles:) primitive

    /// Thin wrapper around IndexStoreDB's `occurrences(ofUSR:roles:)`.
    ///
    /// This is the low-level primitive for "give me every occurrence of
    /// this exact symbol (by USR) matching these roles." It returns raw
    /// IndexStoreDB values; callers are responsible for filtering out
    /// system occurrences, deduplicating, and mapping to `OccurrenceResult`.
    ///
    /// Shared between `findRefs`, `findDefinition`, `blastRadius`, and
    /// the v1.1 `RenamePlanner` so the single path through IndexStoreDB
    /// is testable and behavior stays consistent across tools.
    func occurrences(ofUSR usr: String, roles: SymbolRole) -> [SymbolOccurrence] {
        db.occurrences(ofUSR: usr, roles: roles)
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
            let occurrences = occurrences(
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

    // MARK: - findSymbol

    /// Return candidate symbols matching `symbolName` with kind, language, and
    /// definition location. Useful as a disambiguation step before findRefs/findDefinition.
    func findSymbol(symbolName: String) -> [SymbolResult] {
        var seen = Set<String>()
        var results: [SymbolResult] = []

        let canonical = db.canonicalOccurrences(ofName: symbolName)
        for occ in canonical {
            guard seen.insert(occ.symbol.usr).inserted else { continue }
            guard !occ.location.isSystem else { continue }
            results.append(SymbolResult(
                usr: occ.symbol.usr,
                name: occ.symbol.name,
                kind: occ.symbol.kind.kindDescription,
                language: occ.symbol.language.languageDescription,
                definitionPath: occ.location.path,
                definitionLine: occ.location.line
            ))
        }

        return results.sorted { $0.usr < $1.usr }
    }

    // MARK: - findDefinition

    /// Return the canonical (definition) occurrence for a given USR.
    func findDefinition(usr: String) -> OccurrenceResult? {
        let defOccurrences = occurrences(ofUSR: usr, roles: [.definition])
        guard let occ = defOccurrences.first(where: { !$0.location.isSystem }) else {
            // Fall back to declaration if no definition in user code
            let declOccurrences = occurrences(ofUSR: usr, roles: [.declaration])
            guard let decl = declOccurrences.first(where: { !$0.location.isSystem }) else {
                return nil
            }
            return OccurrenceResult(
                usr: usr,
                symbolName: decl.symbol.name,
                path: decl.location.path,
                line: decl.location.line,
                column: decl.location.utf8Column,
                roles: decl.roles.humanReadable
            )
        }
        return OccurrenceResult(
            usr: usr,
            symbolName: occ.symbol.name,
            path: occ.location.path,
            line: occ.location.line,
            column: occ.location.utf8Column,
            roles: occ.roles.humanReadable
        )
    }

    // MARK: - findOverrides

    /// Return all symbols that override the method/property identified by `usr`.
    ///
    /// Uses the `overrideOf` relation to find the overriding implementations.
    func findOverrides(usr: String) -> [OccurrenceResult] {
        // Symbols that have `overrideOf` relation pointing to our USR
        let related = db.occurrences(relatedToUSR: usr, roles: [.overrideOf])
        var seen = Set<String>()
        var results: [OccurrenceResult] = []

        for occ in related {
            guard !occ.location.isSystem else { continue }
            let key = "\(occ.location.path):\(occ.location.line)"
            guard seen.insert(key).inserted else { continue }
            results.append(OccurrenceResult(
                usr: occ.symbol.usr,
                symbolName: occ.symbol.name,
                path: occ.location.path,
                line: occ.location.line,
                column: occ.location.utf8Column,
                roles: occ.roles.humanReadable
            ))
        }

        return results.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.line < $1.line
        }
    }

    // MARK: - findConformances

    /// Return all types that conform to the protocol identified by `usr`.
    ///
    /// Swift's IndexStoreDB does not record a direct class→protocol
    /// relation; conformance is only recorded as a per-method
    /// `.overrideOf` relation from each witness to the corresponding
    /// protocol requirement. To enumerate conforming types we:
    ///   1. Collect the protocol's requirements (children of the
    ///      protocol USR via `.childOf`).
    ///   2. For each requirement, find the overriding witnesses via
    ///      `.overrideOf`.
    ///   3. From each witness occurrence, walk its relations to find
    ///      the enclosing type (`.childOf`) — that's the conforming
    ///      type.
    ///   4. Return one OccurrenceResult per unique conforming type,
    ///      located at the type's definition site.
    func findConformances(usr: String) -> [OccurrenceResult] {
        let requirements = db.occurrences(relatedToUSR: usr, roles: [.childOf])
        let requirementUSRs = Set(requirements.map(\.symbol.usr))

        var seenTypeUSRs = Set<String>()
        var results: [OccurrenceResult] = []

        for reqUSR in requirementUSRs {
            let witnesses = db.occurrences(relatedToUSR: reqUSR, roles: [.overrideOf])
            for witness in witnesses {
                for relation in witness.relations where relation.roles.contains(.childOf) {
                    let typeUSR = relation.symbol.usr
                    guard seenTypeUSRs.insert(typeUSR).inserted else { continue }

                    let defs = occurrences(ofUSR: typeUSR, roles: [.definition])
                    guard let def = defs.first(where: { !$0.location.isSystem }) else {
                        continue
                    }
                    results.append(OccurrenceResult(
                        usr: typeUSR,
                        symbolName: def.symbol.name,
                        path: def.location.path,
                        line: def.location.line,
                        column: def.location.utf8Column,
                        roles: def.roles.humanReadable
                    ))
                }
            }
        }

        return results.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.line < $1.line
        }
    }

    // MARK: - blastRadius

    /// Given a source file path, return the minimal set of files that depend on it:
    ///   - direct dependents (files that import/include this file, or call its symbols)
    ///   - transitive callers (files of callers' callers, one hop)
    ///   - covering tests (test files in the affected set)
    ///
    /// This is the token-saving query: Claude reads only these files, not the whole repo.
    func blastRadius(filePath: String) -> BlastRadiusResult {
        // Step 1: find all symbols defined in `filePath`
        let definedSymbols = db.symbols(inFilePath: filePath)

        // Step 2: for each symbol, find all reference sites outside `filePath`
        var directCallerFiles = Set<String>()
        for symbol in definedSymbols {
            let refs = occurrences(
                ofUSR: symbol.usr,
                roles: [.reference, .call, .read, .write]
            )
            for ref in refs {
                guard !ref.location.isSystem, ref.location.path != filePath else { continue }
                directCallerFiles.insert(ref.location.path)
            }
        }

        // Step 3: one hop of transitive callers
        // Find symbols defined in directCallerFiles, then their callers
        var transitiveFiles = Set<String>()
        for callerFile in directCallerFiles {
            let callerSymbols = db.symbols(inFilePath: callerFile)
            for sym in callerSymbols {
                let refs = occurrences(ofUSR: sym.usr, roles: [.reference, .call])
                for ref in refs {
                    guard !ref.location.isSystem,
                          ref.location.path != filePath,
                          !directCallerFiles.contains(ref.location.path) else { continue }
                    transitiveFiles.insert(ref.location.path)
                }
            }
        }

        let allAffected = Array(directCallerFiles.union(transitiveFiles)).sorted()
        let directDeps = directCallerFiles.sorted()

        // Heuristic: test files contain "Test" or "Spec" in their filename
        let tests = allAffected.filter { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.contains("Test") || name.contains("Spec")
        }

        return BlastRadiusResult(
            affectedFiles: allAffected,
            coveringTests: tests,
            directDependents: directDeps
        )
    }

    // MARK: - status

    /// Return freshness info about the index store.
    func status(storePath: String) -> StatusResult {
        let fm = FileManager.default
        var indexMtime: String? = nil

        if let attrs = try? fm.attributesOfItem(atPath: storePath),
           let mtime = attrs[.modificationDate] as? Date {
            let formatter = ISO8601DateFormatter()
            indexMtime = formatter.string(from: mtime)
        }

        return StatusResult(
            indexStorePath: storePath,
            indexMtime: indexMtime,
            staleFileCount: 0, // populated by the TS layer which tracks session edits
            staleFiles: [],
            summary: indexMtime == nil
                ? "Index store not found at \(storePath)."
                : "Index store found at \(storePath) (last modified \(indexMtime!))."
        )
    }
}

// MARK: - IndexSymbolKind description

extension IndexSymbolKind {
    var kindDescription: String {
        switch self {
        case .unknown: return "unknown"
        case .module: return "module"
        case .namespace: return "namespace"
        case .namespaceAlias: return "namespaceAlias"
        case .macro: return "macro"
        case .enum: return "enum"
        case .struct: return "struct"
        case .class: return "class"
        case .protocol: return "protocol"
        case .extension: return "extension"
        case .union: return "union"
        case .typealias: return "typealias"
        case .function: return "function"
        case .variable: return "variable"
        case .field: return "field"
        case .enumConstant: return "enumCase"
        case .instanceMethod: return "instanceMethod"
        case .classMethod: return "classMethod"
        case .staticMethod: return "staticMethod"
        case .instanceProperty: return "instanceProperty"
        case .classProperty: return "classProperty"
        case .staticProperty: return "staticProperty"
        case .constructor: return "constructor"
        case .destructor: return "destructor"
        case .conversionFunction: return "conversionFunction"
        case .parameter: return "parameter"
        case .using: return "using"
        case .concept: return "concept"
        case .commentTag: return "commentTag"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Language description

extension Language {
    var languageDescription: String {
        switch self {
        case .c: return "c"
        case .cxx: return "c++"
        case .objc: return "objc"
        case .swift: return "swift"
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
                        .deletingLastPathComponent() // bin
                        .deletingLastPathComponent() // usr
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
        if contains(.definition) { names.append("definition") }
        if contains(.declaration) { names.append("declaration") }
        if contains(.reference) { names.append("reference") }
        if contains(.call) { names.append("call") }
        if contains(.read) { names.append("read") }
        if contains(.write) { names.append("write") }
        if contains(.dynamic) { names.append("dynamic") }
        if contains(.addressOf) { names.append("addressOf") }
        if contains(.implicit) { names.append("implicit") }
        if contains(.overrideOf) { names.append("overrideOf") }
        if contains(.accessorOf) { names.append("accessorOf") }
        if contains(.childOf) { names.append("childOf") }
        if contains(.baseOf) { names.append("baseOf") }
        if contains(.extendedBy) { names.append("extendedBy") }
        if contains(.receivedBy) { names.append("receivedBy") }
        if contains(.calledBy) { names.append("calledBy") }
        if contains(.containedBy) { names.append("containedBy") }
        if contains(.specializationOf) { names.append("specializationOf") }
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
