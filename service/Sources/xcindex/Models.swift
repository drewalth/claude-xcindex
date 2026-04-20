import Foundation

// MARK: - Wire types for stdio JSON-RPC

struct Request: Codable {
    /// Operations: findRefs, findSymbol, findDefinition, findOverrides,
    ///              findConformances, blastRadius, status, planRename
    let op: String

    /// Path to .xcodeproj or .xcworkspace — used for DerivedData discovery
    let projectPath: String?

    /// Direct path to the IndexStore DataStore directory (overrides projectPath discovery)
    let indexStorePath: String?

    /// Symbol name to search for (human-readable, e.g. "MyViewController")
    let symbolName: String?

    /// Unified Symbol Resolution identifier — used for direct USR lookups
    let usr: String?

    /// Source file path — used for blastRadius
    let filePath: String?

    /// Proposed new identifier — used for planRename
    let newName: String?

    init(
        op: String,
        projectPath: String? = nil,
        indexStorePath: String? = nil,
        symbolName: String? = nil,
        usr: String? = nil,
        filePath: String? = nil,
        newName: String? = nil
    ) {
        self.op = op
        self.projectPath = projectPath
        self.indexStorePath = indexStorePath
        self.symbolName = symbolName
        self.usr = usr
        self.filePath = filePath
        self.newName = newName
    }
}

struct SymbolResult: Codable {
    let usr: String
    let name: String
    let kind: String
    let language: String
    let definitionPath: String?
    let definitionLine: Int?
}

struct OccurrenceResult: Codable {
    let usr: String
    let symbolName: String
    let path: String
    let line: Int
    let column: Int
    let roles: [String]
}

struct StatusResult: Codable {
    let indexStorePath: String
    let indexMtime: String?
    let staleFileCount: Int
    let staleFiles: [String]
    let summary: String
}

struct BlastRadiusResult: Codable {
    /// Files that directly or transitively depend on the queried file.
    let affectedFiles: [String]
    /// Test files in the affected set (subset of affectedFiles).
    let coveringTests: [String]
    /// Files that include the queried file (direct dependents).
    let directDependents: [String]
}

struct Response: Codable {
    var error: String?
    var symbols: [SymbolResult]?
    var occurrences: [OccurrenceResult]?
    var status: StatusResult?
    var blastRadius: BlastRadiusResult?
    var renamePlan: RenamePlan?

    init(error: String) {
        self.error = error
    }

    init(occurrences: [OccurrenceResult]) {
        self.occurrences = occurrences
    }

    init(symbols: [SymbolResult]) {
        self.symbols = symbols
    }

    init(status: StatusResult) {
        self.status = status
    }

    init(blastRadius: BlastRadiusResult) {
        self.blastRadius = blastRadius
    }

    init(renamePlan: RenamePlan) {
        self.renamePlan = renamePlan
    }
}
