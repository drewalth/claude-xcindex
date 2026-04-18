import Foundation

// MARK: - Wire types for stdio JSON-RPC

struct Request: Codable {
    /// Operation: "findRefs" (step 1), more ops added in later steps
    let op: String

    /// Path to .xcodeproj or .xcworkspace — used for DerivedData discovery
    let projectPath: String?

    /// Direct path to the IndexStore DataStore directory (overrides projectPath discovery)
    let indexStorePath: String?

    /// Symbol name to search for (human-readable, e.g. "MyViewController")
    let symbolName: String?

    /// Unified Symbol Resolution identifier — used for direct USR lookups in later ops
    let usr: String?
}

struct SymbolResult: Codable {
    let usr: String
    let name: String
    let kind: String
}

struct OccurrenceResult: Codable {
    let usr: String
    let symbolName: String
    let path: String
    let line: Int
    let column: Int
    let roles: [String]
}

struct Response: Codable {
    var error: String?
    var symbols: [SymbolResult]?
    var occurrences: [OccurrenceResult]?

    init(error: String) {
        self.error = error
    }

    init(occurrences: [OccurrenceResult]) {
        self.occurrences = occurrences
    }

    init(symbols: [SymbolResult]) {
        self.symbols = symbols
    }
}
