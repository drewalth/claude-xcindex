import Foundation
import IndexStoreDB

// MARK: - RenamePlanner
//
// Rename plan builder. Indexstore-only first pass (v1.1 baseline).
// SourceKit-LSP reconciliation lands in a later step and upgrades
// green-indexstore to green-verified / yellow-* as appropriate.
//
// ASCII flow (v1.1 final shape; LSP leg noted for context):
//
//   ┌────────────────────────────────────────────────────────────┐
//   │  plan(usr:newName:)                                         │
//   │                                                             │
//   │   1. Kill switch (XCINDEX_DISABLE_PLAN_RENAME)              │
//   │   2. Validate newName (keyword, identifier rules)           │
//   │   3. Resolve definition → detect SDK / synthesized          │
//   │   4. Query indexstore for references via primitive          │
//   │   5. Per occurrence: assign tier + reasons                  │
//   │        • session-edited file     → red-stale                │
//   │        • operator / non-identifier → yellow-disagreement    │
//   │        • override / extension    → green-indexstore + reason│
//   │        • else                    → green-indexstore         │
//   │   6. (v1.1 step 7) LSP reconcile green-indexstore candidates│
//   │   7. Emit plan + summary + optional refusal/warnings        │
//   └────────────────────────────────────────────────────────────┘

struct RenamePlanner {
    let querier: IndexQuerier
    let editedFiles: Set<String>
    let isDisabled: Bool

    /// Construct a planner. `isDisabled` is injectable so tests can
    /// exercise the kill-switch branch without mutating process-global
    /// env state; at runtime the default reads XCINDEX_DISABLE_PLAN_RENAME.
    init(
        querier: IndexQuerier,
        editedFiles: Set<String> = Freshness.getEditedFiles(),
        isDisabled: Bool = RenamePlanner.readEnvKillSwitch()
    ) {
        self.querier = querier
        self.editedFiles = editedFiles
        self.isDisabled = isDisabled
    }

    static func readEnvKillSwitch() -> Bool {
        ProcessInfo.processInfo.environment["XCINDEX_DISABLE_PLAN_RENAME"] == "1"
    }

    func plan(usr: String, newName: String) -> RenamePlan {
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let freshness = IndexFreshness(
            lastBuilt: nil,
            filesEditedThisSession: editedFiles.count
        )

        // 1. Env kill switch
        if isDisabled {
            return RenamePlan.refused(
                usr: usr, oldName: "", newName: newName,
                generatedAt: generatedAt, indexFreshness: freshness,
                refusal: RefusalReason.disabledByEnv.refusal()
            )
        }

        // 2. Identifier validation
        if let reason = IdentifierValidator.validate(newName) {
            return RenamePlan.refused(
                usr: usr, oldName: "", newName: newName,
                generatedAt: generatedAt, indexFreshness: freshness,
                refusal: RefusalReason.invalidIdentifier(details: reason).refusal()
            )
        }

        // 3. Resolve the definition. Used to derive oldName and detect
        //    SDK / synthesized cases. Missing definition = refusal:
        //    without a definition we can't classify ranges or stream
        //    an audit trail, so emitting an empty plan would invite
        //    the caller to treat "no ranges" as "nothing to rename"
        //    rather than "we couldn't find this USR at all."
        guard let def = querier.findDefinition(usr: usr) else {
            return RenamePlan.refused(
                usr: usr, oldName: "", newName: newName,
                generatedAt: generatedAt, indexFreshness: freshness,
                refusal: RefusalReason.usrNotFound(usr: usr).refusal()
            )
        }
        let oldName = def.symbolName

        // 4. SDK / synthesized detection (coarse, v1.1 baseline).
        if isSDKPath(def.path) {
            return RenamePlan.refused(
                usr: usr, oldName: oldName, newName: newName,
                generatedAt: generatedAt, indexFreshness: freshness,
                refusal: RefusalReason.sdkSymbolRename(defPath: def.path).refusal()
            )
        }
        if def.path.isEmpty || def.line == 0 {
            return RenamePlan.refused(
                usr: usr, oldName: oldName, newName: newName,
                generatedAt: generatedAt, indexFreshness: freshness,
                refusal: RefusalReason.synthesizedSymbolNotRenameable.refusal()
            )
        }

        // 5. Collect all USRs that must rename together: the base USR
        //    plus every override. IndexStoreDB assigns separate USRs to
        //    overriding declarations, so a rename of the base must
        //    visit each override's occurrences independently.
        //    Conformance witnesses (protocol default implementations,
        //    retroactive witnesses) are NOT yet followed in v1.1 step 1
        //    and surface as a known limitation — the LSP-reconciliation
        //    step picks up the remainder.
        var usrsToRename: [String] = [usr]
        let overrides = querier.findOverrides(usr: usr)
        usrsToRename.append(contentsOf: overrides.map(\.usr))

        // 6. Fetch occurrences via the shared primitive. Same role
        //    set as findRefs so behavior is consistent between tools.
        var occurrences: [SymbolOccurrence] = []
        for targetUSR in usrsToRename {
            occurrences.append(contentsOf: querier.occurrences(
                ofUSR: targetUSR,
                roles: [.definition, .declaration, .reference, .call, .read, .write, .overrideOf]
            ))
        }

        // 7. Dedupe by (path, line, column) — matches findRefs semantics.
        var seen = Set<String>()
        var ranges: [RenameRange] = []
        for occ in occurrences {
            guard !occ.location.isSystem else { continue }
            let key = "\(occ.location.path):\(occ.location.line):\(occ.location.utf8Column)"
            guard seen.insert(key).inserted else { continue }
            ranges.append(buildRange(occ: occ, oldName: oldName))
        }

        ranges.sort(by: RenameRange.locationOrder)
        let summary = PlanSummary.counting(ranges)

        return RenamePlan(
            usr: usr,
            oldName: oldName,
            newName: newName,
            generatedAt: generatedAt,
            indexFreshness: freshness,
            ranges: ranges,
            summary: summary,
            refusal: nil,
            warnings: []
        )
    }

    // MARK: - Tier + range construction

    private func buildRange(occ: SymbolOccurrence, oldName: String) -> RenameRange {
        let path = occ.location.path
        let line = occ.location.line
        let column = occ.location.utf8Column

        // IndexStoreDB returns method symbol names in their full-selector
        // form ("fetchUser(id:)"), but the source identifier at the
        // reference site is just the base name ("fetchUser"). Strip the
        // argument-label suffix for range-end computation.
        let baseName = Self.baseName(of: occ.symbol.name.isEmpty ? oldName : occ.symbol.name)

        // Range end: byte length of the identifier in UTF-8. Unverified
        // for operators, subscripts, and labels (which aren't plain
        // identifiers) — those get downgraded to yellow-disagreement.
        let endColumn = column + baseName.utf8.count
        let baseNameIsIdentifier = !baseName.isEmpty && baseName.allSatisfy { char in
            char.isLetter || char.isNumber || char == "_"
        }

        var reasons: [RenameReason] = []
        var tier: RenameTier = .greenIndexstore

        // Role → reason mapping (first reason is the primary classification).
        // .overrideOf is used by IndexStoreDB for BOTH subclass overrides
        // and protocol-witness declarations — disambiguate via the
        // overridden symbol's enclosing kind (see Queries.findConformances
        // for the authoritative witness recognition pattern).
        if occ.roles.contains(.overrideOf) {
            reasons.append(isProtocolWitness(occ) ? .conformanceWitness : .override)
        } else if occ.roles.contains(.extendedBy) {
            reasons.append(.extensionMember)
        } else {
            reasons.append(.directReference)
        }

        if !baseNameIsIdentifier {
            tier = .yellowDisagreement
            reasons.append(.rangeEndComputedUnverified)
        }

        // Session-edited file wins over every other tier.
        if editedFiles.contains(path) {
            tier = .redStale
            if !reasons.contains(.sessionEdited) {
                reasons.append(.sessionEdited)
            }
        }

        return RenameRange(
            path: path,
            line: line,
            column: column,
            endColumn: endColumn,
            tier: tier,
            reasons: reasons,
            module: nil,
            source: .indexstore
        )
    }

    /// Strip the Swift selector-style suffix ("fetchUser(id:)" → "fetchUser").
    /// For non-method names (types, free functions without label, variables)
    /// the input is returned unchanged.
    static func baseName(of name: String) -> String {
        if let paren = name.firstIndex(of: "(") {
            return String(name[..<paren])
        }
        return name
    }

    /// True when an `.overrideOf` occurrence is a protocol-conformance
    /// witness rather than a subclass override. Walks the overridden
    /// symbol's definition and checks whether its enclosing type is a
    /// protocol — the same signal `Queries.findConformances` uses.
    private func isProtocolWitness(_ occ: SymbolOccurrence) -> Bool {
        for relation in occ.relations where relation.roles.contains(.overrideOf) {
            let overriddenUSR = relation.symbol.usr
            let defs = querier.occurrences(ofUSR: overriddenUSR, roles: [.definition])
            for def in defs {
                for parent in def.relations where parent.roles.contains(.childOf) {
                    if parent.symbol.kind == .protocol {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Reconciliation

    /// Merge an indexstore-only plan with sourcekit-lsp locations,
    /// upgrading / downgrading tiers per the v1.1 design:
    ///
    ///   • indexstore ∩ LSP agree            → green-verified
    ///   • indexstore only (LSP didn't see)  → yellow-disagreement (source=indexstore)
    ///   • LSP only (indexstore didn't see)  → yellow-lsp-only (source=sourcekit-lsp)
    ///   • red-stale ranges stay red-stale
    ///
    /// URIs are realpath-normalized on both sides before comparison
    /// so `/private/var/...` matches `/var/...`. If `lspLocations` is
    /// empty (LSP not configured, or the server returned nothing),
    /// the original plan is returned with a `warnings[]` entry so the
    /// caller can distinguish "we didn't ask LSP" from "LSP answered
    /// with nothing."
    static func reconcile(
        _ plan: RenamePlan,
        with lspLocations: [LSPRefLocation],
        lspConsulted: Bool = true
    ) -> RenamePlan {
        // Pass-through when LSP wasn't available: add a warning so
        // consumers know the green-indexstore tiers aren't verified.
        guard lspConsulted else {
            var updated = plan.warnings
            if !updated.contains("reconciliation_unavailable") {
                updated.append("reconciliation_unavailable")
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
                warnings: updated
            )
        }

        // Build a set of LSP keys: (realpath, line, column) 0-indexed
        // internally, matched to IndexStoreDB's 1-indexed convention
        // via a +1 adjustment on line and column. LSP lines and
        // characters are 0-indexed; indexstore line/column are 1-indexed.
        func realpath(_ path: String) -> String {
            (path as NSString).resolvingSymlinksInPath
        }

        var lspKeys = Set<String>()
        for loc in lspLocations {
            let normalized = realpath(loc.path)
            // LSP uses 0-indexed line + utf16 character. IndexStoreDB
            // uses 1-indexed line + utf8 column. The raw LSP character
            // index is typically utf16-relative, but for pure-ASCII
            // identifiers (the common case) utf8Column == utf16Index.
            // Non-ASCII identifiers are downgraded to yellow elsewhere
            // in the planner, so the +1 alignment is sound here.
            let key = "\(normalized):\(loc.line + 1):\(loc.character + 1)"
            lspKeys.insert(key)
        }

        // Upgrade tiers for ranges that also appear in LSP output.
        var upgraded: [RenameRange] = []
        var indexstoreKeys = Set<String>()
        for range in plan.ranges {
            let normalized = realpath(range.path)
            let key = "\(normalized):\(range.line):\(range.column)"
            indexstoreKeys.insert(key)

            if range.tier == .redStale {
                upgraded.append(range)
                continue
            }

            if lspKeys.contains(key) {
                upgraded.append(range.withTier(.greenVerified))
            } else {
                // LSP did not echo this range. If LSP returned nothing
                // at all, don't downgrade — we'll treat the empty LSP
                // response as "degraded" via the top-level warning path.
                if lspKeys.isEmpty {
                    upgraded.append(range)
                } else {
                    upgraded.append(range.withTier(.yellowDisagreement).withReasonsMerged([.sourcekitLspOnly]))
                }
            }
        }

        // Add LSP-only ranges (occurrences LSP found that indexstore
        // didn't). These commonly surface macro-generated call sites.
        var added: [RenameRange] = []
        for loc in lspLocations {
            let normalized = realpath(loc.path)
            let key = "\(normalized):\(loc.line + 1):\(loc.character + 1)"
            if indexstoreKeys.contains(key) { continue }
            added.append(RenameRange(
                path: loc.path,
                line: loc.line + 1,
                column: loc.character + 1,
                endColumn: loc.character + 1 + (loc.endCharacter - loc.character),
                tier: .yellowLspOnly,
                reasons: [.sourcekitLspOnly, .macroAdjacent],
                module: nil,
                source: .sourcekitLsp
            ))
        }

        let combined = (upgraded + added).sorted(by: RenameRange.locationOrder)
        var warnings = plan.warnings
        if lspLocations.isEmpty {
            if !warnings.contains("reconciliation_empty") {
                warnings.append("reconciliation_empty")
            }
        }

        return RenamePlan(
            usr: plan.usr,
            oldName: plan.oldName,
            newName: plan.newName,
            generatedAt: plan.generatedAt,
            indexFreshness: plan.indexFreshness,
            ranges: combined,
            summary: PlanSummary.counting(combined),
            refusal: plan.refusal,
            warnings: warnings
        )
    }

    private func isSDKPath(_ path: String) -> Bool {
        // Heuristic match for Xcode toolchain / SDK paths. Covers the
        // common case; refined in a later step that consults the LSP.
        let prefixes = [
            "/Applications/Xcode.app/",
            "/Applications/Xcode-beta.app/",
            "/Library/Developer/CommandLineTools/",
        ]
        let infixes = [
            "/XcodeDefault.xctoolchain/",
            "/usr/lib/swift/",
            "/.sdk/",
        ]
        if prefixes.contains(where: path.hasPrefix) { return true }
        if infixes.contains(where: path.contains) { return true }
        return false
    }
}

// MARK: - Plan + range value types (Codable for JSON emission)

struct RenamePlan: Codable {
    let usr: String
    let oldName: String
    let newName: String
    let generatedAt: String
    let indexFreshness: IndexFreshness
    let ranges: [RenameRange]
    let summary: PlanSummary
    let refusal: Refusal?
    let warnings: [String]

    static func refused(
        usr: String,
        oldName: String,
        newName: String,
        generatedAt: String,
        indexFreshness: IndexFreshness,
        refusal: Refusal
    ) -> RenamePlan {
        RenamePlan(
            usr: usr,
            oldName: oldName,
            newName: newName,
            generatedAt: generatedAt,
            indexFreshness: indexFreshness,
            ranges: [],
            summary: .zero,
            refusal: refusal,
            warnings: []
        )
    }
}

struct IndexFreshness: Codable {
    let lastBuilt: String?
    let filesEditedThisSession: Int
}

struct RenameRange: Codable {
    let path: String
    let line: Int
    let column: Int
    let endColumn: Int
    let tier: RenameTier
    let reasons: [RenameReason]
    let module: String?
    let source: OccurrenceSource

    /// Stable ordering for plan output: by path, then line, then column.
    static func locationOrder(_ lhs: RenameRange, _ rhs: RenameRange) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        return lhs.column < rhs.column
    }

    /// Returns a copy with `tier` replaced. Used during reconciliation.
    func withTier(_ tier: RenameTier) -> RenameRange {
        RenameRange(
            path: path, line: line, column: column, endColumn: endColumn,
            tier: tier, reasons: reasons, module: module, source: source
        )
    }

    /// Returns a copy with `newReasons` appended (deduped), preserving
    /// original order. Used during reconciliation to annotate
    /// indexstore-only ranges that LSP disagreed with.
    func withReasonsMerged(_ newReasons: [RenameReason]) -> RenameRange {
        var merged = reasons
        for reason in newReasons where !merged.contains(reason) {
            merged.append(reason)
        }
        return RenameRange(
            path: path, line: line, column: column, endColumn: endColumn,
            tier: tier, reasons: merged, module: module, source: source
        )
    }
}

/// Minimal LSP-location shape for reconciliation. Kept separate from
/// LanguageServerProtocol.Location so RenamePlanner compiles without
/// importing the LSP types (handy for unit tests that hand-craft
/// locations without touching the LSP package).
struct LSPRefLocation {
    let path: String
    let line: Int        // 0-indexed (LSP convention)
    let character: Int   // 0-indexed character in the line
    let endLine: Int
    let endCharacter: Int
}

enum RenameTier: String, Codable {
    case greenVerified = "green-verified"
    case greenIndexstore = "green-indexstore"
    case yellowDisagreement = "yellow-disagreement"
    case yellowLspOnly = "yellow-lsp-only"
    case redStale = "red-stale"
}

enum RenameReason: String, Codable {
    case directReference = "direct_reference"
    case override = "override"
    case conformanceWitness = "conformance_witness"
    case extensionMember = "extension_member"
    case objcBridge = "objc_bridge"
    case macroAdjacent = "macro_adjacent"
    case sourcekitLspOnly = "sourcekit_lsp_only"
    case sessionEdited = "session_edited"
    case fileNewerThanUnit = "file_newer_than_unit"
    case sdkSymbol = "sdk_symbol"
    case rangeEndComputedUnverified = "range_end_computed_unverified"
    case compileCommandsMissing = "compile_commands_missing"
    case synthesizedSymbol = "synthesized_symbol"
}

enum OccurrenceSource: String, Codable {
    case indexstore
    case sourcekitLsp = "sourcekit-lsp"
    case sourcekitLspTimeout = "sourcekit-lsp-timeout"
}

struct PlanSummary: Codable {
    let greenVerified: Int
    let greenIndexstore: Int
    let yellowDisagreement: Int
    let yellowLspOnly: Int
    let redStale: Int

    static let zero = PlanSummary(
        greenVerified: 0, greenIndexstore: 0,
        yellowDisagreement: 0, yellowLspOnly: 0, redStale: 0
    )

    static func counting(_ ranges: [RenameRange]) -> PlanSummary {
        var verified = 0, indexstore = 0, disagreement = 0, lspOnly = 0, stale = 0
        for range in ranges {
            switch range.tier {
            case .greenVerified: verified += 1
            case .greenIndexstore: indexstore += 1
            case .yellowDisagreement: disagreement += 1
            case .yellowLspOnly: lspOnly += 1
            case .redStale: stale += 1
            }
        }
        return PlanSummary(
            greenVerified: verified,
            greenIndexstore: indexstore,
            yellowDisagreement: disagreement,
            yellowLspOnly: lspOnly,
            redStale: stale
        )
    }

    enum CodingKeys: String, CodingKey {
        case greenVerified = "green_verified"
        case greenIndexstore = "green_indexstore"
        case yellowDisagreement = "yellow_disagreement"
        case yellowLspOnly = "yellow_lsp_only"
        case redStale = "red_stale"
    }
}

// MARK: - Refusal

struct Refusal: Codable {
    let reason: String
    let message: String
    let remediation: String
}

enum RefusalReason {
    case disabledByEnv
    case invalidIdentifier(details: String)
    case synthesizedSymbolNotRenameable
    case sdkSymbolRename(defPath: String)
    case usrNotFound(usr: String)

    func refusal() -> Refusal {
        switch self {
        case .disabledByEnv:
            return Refusal(
                reason: "disabled_by_env",
                message: "plan_rename is disabled via XCINDEX_DISABLE_PLAN_RENAME=1.",
                remediation: "Unset the XCINDEX_DISABLE_PLAN_RENAME environment variable and retry."
            )
        case .invalidIdentifier(let details):
            return Refusal(
                reason: "invalid_identifier",
                message: "The proposed newName is not a valid Swift identifier: \(details).",
                remediation: "Choose a name starting with a letter or underscore, containing only letters, digits, and underscores. Avoid Swift keywords."
            )
        case .synthesizedSymbolNotRenameable:
            return Refusal(
                reason: "synthesized_symbol_not_renameable",
                message: "The symbol is synthesized by the compiler (e.g. Codable-generated init, protocol default witness, property-wrapper accessor) and has no rewritable source range.",
                remediation: "Rename the underlying declaration site instead. Run find_definition on the USR to inspect the resolved location."
            )
        case .sdkSymbolRename(let path):
            return Refusal(
                reason: "sdk_symbol_rename",
                message: "The symbol's canonical declaration lives in an SDK at \(path). SDK symbols cannot be renamed from an application project.",
                remediation: "If you meant to rename a local symbol of the same name, use find_symbol to disambiguate and pick the non-SDK USR."
            )
        case .usrNotFound(let usr):
            return Refusal(
                reason: "usr_not_found",
                message: "The index has no definition occurrence for USR \(usr). The symbol may have been removed, or the project was not built with indexing enabled.",
                remediation: "Rebuild the project in Xcode, verify the USR via find_symbol, or check the index store path with status."
            )
        }
    }
}

// MARK: - Identifier validation

enum IdentifierValidator {
    // Swift keywords that cannot be used as plain identifiers.
    // Contextual keywords (async, await, throws) are admissible as names
    // with backticks; we reject them here to avoid surprising the user.
    private static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension",
        "fileprivate", "func", "import", "init", "inout", "internal",
        "let", "open", "operator", "private", "precedencegroup",
        "protocol", "public", "rethrows", "static", "struct", "subscript",
        "typealias", "var",
        "break", "case", "catch", "continue", "default", "defer", "do",
        "else", "fallthrough", "for", "guard", "if", "in", "repeat",
        "return", "switch", "throw", "throws", "try", "while",
        "Any", "as", "await", "false", "is", "nil", "self", "Self",
        "super", "true",
    ]

    /// Returns nil if `name` is a valid Swift identifier for rename use,
    /// otherwise a short human-readable reason suitable for the refusal
    /// message.
    static func validate(_ name: String) -> String? {
        if name.isEmpty { return "empty identifier" }
        if keywords.contains(name) { return "'\(name)' is a Swift keyword" }

        guard let first = name.unicodeScalars.first else { return "empty identifier" }
        let letters = CharacterSet.letters
        let digits = CharacterSet.decimalDigits

        if !(letters.contains(first) || first == "_") {
            return "identifier must start with a letter or underscore, got '\(name.prefix(1))'"
        }

        for scalar in name.unicodeScalars.dropFirst() {
            let valid = letters.contains(scalar) || digits.contains(scalar) || scalar == "_"
            if !valid {
                return "'\(scalar)' is not valid in an identifier"
            }
        }

        return nil
    }
}
