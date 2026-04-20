import Foundation
import MCP

// MARK: - Server builder

enum XcindexServer {
    static let name = "claude-xcindex"
    static let version = "2.0.0"

    static func makeServer() -> Server {
        Server(
            name: name,
            version: version,
            capabilities: .init(tools: .init(listChanged: false))
        )
    }

    static func register(on server: Server, processor: RequestProcessor) async {
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolDefinitions.all)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await Dispatcher.handle(name: params.name, arguments: params.arguments, processor: processor)
        }
    }
}

// MARK: - JSON Schema helpers

private enum Schema {
    static func object(properties: [String: Value], required: [String] = []) -> Value {
        var obj: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            obj["required"] = .array(required.map { .string($0) })
        }
        return .object(obj)
    }

    static func string(_ description: String) -> Value {
        .object([
            "type": .string("string"),
            "description": .string(description),
        ])
    }

    static func integer(_ description: String, min: Int? = nil, max: Int? = nil, default: Int? = nil) -> Value {
        var obj: [String: Value] = [
            "type": .string("integer"),
            "description": .string(description),
        ]
        if let min { obj["minimum"] = .int(min) }
        if let max { obj["maximum"] = .int(max) }
        if let def = `default` { obj["default"] = .int(def) }
        return .object(obj)
    }

    /// Shared project/index-store params every tool accepts.
    static var projectParams: [String: Value] {
        [
            "projectPath": string(
                "Absolute path to the .xcodeproj or .xcworkspace file. " +
                    "Used to locate DerivedData automatically. " +
                    "Omit if you supply indexStorePath directly."
            ),
            "indexStorePath": string(
                "Absolute path to the IndexStore DataStore directory. " +
                    "Overrides projectPath. Use status to find this path."
            ),
        ]
    }
}

// MARK: - Tool definitions

private enum ToolDefinitions {
    static let all: [Tool] = [
        findReferences,
        findSymbol,
        findDefinition,
        findOverrides,
        findConformances,
        blastRadius,
        status,
        planRename,
    ]

    static let findReferences = Tool(
        name: "find_references",
        description:
        "Find every occurrence of a Swift/ObjC symbol in Xcode's pre-built semantic index. " +
            "Returns exact file+line+column+role for each reference — no false positives from " +
            "comments, strings, or same-named symbols in other modules. " +
            "Call find_symbol first if you need to disambiguate overloads. " +
            "Requires the project to have been built in Xcode at least once.",
        inputSchema: Schema.object(
            properties: [
                "symbolName": Schema.string(
                    "Exact name of the symbol to look up (e.g. 'UserService', 'fetchUser', 'AuthProtocol'). " +
                        "Case-sensitive. Use the declaration name, not a qualified path."
                ),
                "projectPath": Schema.projectParams["projectPath"]!,
                "indexStorePath": Schema.projectParams["indexStorePath"]!,
                "maxResults": Schema.integer(
                    "Cap on the number of occurrences returned (default 100, max 500). " +
                        "For very common symbols, increase only if you need the full picture.",
                    min: 1, max: 500, default: 100
                ),
            ],
            required: ["symbolName"]
        )
    )

    static let findSymbol = Tool(
        name: "find_symbol",
        description:
        "Look up a symbol by name and return its kind, language, USR, and definition location. " +
            "Use this BEFORE find_references or find_definition to disambiguate " +
            "overloaded names (e.g. multiple types named 'Delegate' in different modules). " +
            "Returns one result per distinct symbol that exactly matches the name.",
        inputSchema: Schema.object(
            properties: [
                "symbolName": Schema.string(
                    "Exact symbol name to look up (case-sensitive). " +
                        "E.g. 'URLSession', 'fetchUser', 'AuthDelegate'."
                ),
                "projectPath": Schema.projectParams["projectPath"]!,
                "indexStorePath": Schema.projectParams["indexStorePath"]!,
            ],
            required: ["symbolName"]
        )
    )

    static let findDefinition = Tool(
        name: "find_definition",
        description:
        "Return the canonical definition site (file + line) for a symbol identified by USR. " +
            "Use after find_symbol to jump to the declaration. " +
            "More precise than text search because it uses the semantic USR, not the symbol name.",
        inputSchema: Schema.object(
            properties: [
                "usr": Schema.string(usrDescription),
                "projectPath": Schema.projectParams["projectPath"]!,
                "indexStorePath": Schema.projectParams["indexStorePath"]!,
            ],
            required: ["usr"]
        )
    )

    static let findOverrides = Tool(
        name: "find_overrides",
        description:
        "Find all classes or structs that override a given method or property. " +
            "Essential before changing a method signature in a base class. " +
            "Pass the USR from find_symbol for the base method.",
        inputSchema: Schema.object(
            properties: [
                "usr": Schema.string(usrDescription),
                "projectPath": Schema.projectParams["projectPath"]!,
                "indexStorePath": Schema.projectParams["indexStorePath"]!,
            ],
            required: ["usr"]
        )
    )

    static let findConformances = Tool(
        name: "find_conformances",
        description:
        "Find all types that conform to a Swift protocol. " +
            "Pass the protocol's USR from find_symbol. " +
            "More reliable than searching for ': ProtocolName' in source — handles type aliases and " +
            "retroactive conformances declared in other files.",
        inputSchema: Schema.object(
            properties: [
                "usr": Schema.string(usrDescription),
                "projectPath": Schema.projectParams["projectPath"]!,
                "indexStorePath": Schema.projectParams["indexStorePath"]!,
            ],
            required: ["usr"]
        )
    )

    static let blastRadius = Tool(
        name: "blast_radius",
        description:
        "Given a source file path, return the minimal set of files you need to read before " +
            "editing it: direct dependents (files that call its symbols), one hop of transitive " +
            "callers, and the covering test files. " +
            "Call this BEFORE reading files when the user asks 'what does this file affect?' or " +
            "before making changes to a shared utility. " +
            "Avoids reading the entire codebase — just the relevant slice.",
        inputSchema: Schema.object(
            properties: [
                "filePath": Schema.string(
                    "Absolute path to the Swift/ObjC source file to analyse. " +
                        "E.g. '/Users/me/MyApp/Sources/AuthService.swift'."
                ),
                "projectPath": Schema.projectParams["projectPath"]!,
                "indexStorePath": Schema.projectParams["indexStorePath"]!,
            ],
            required: ["filePath"]
        )
    )

    static let status = Tool(
        name: "status",
        description:
        "Check the freshness of the Xcode index for a project. " +
            "Returns the index store path, last-build timestamp, and whether any source files " +
            "edited this session are newer than the index. " +
            "Call this first if you suspect the index is stale, or at session start when working " +
            "on a large Swift project.",
        inputSchema: Schema.object(
            properties: [
                "projectPath": Schema.projectParams["projectPath"]!,
                "indexStorePath": Schema.projectParams["indexStorePath"]!,
            ]
        )
    )

    static let usrDescription =
        "Unified Symbol Resolution identifier obtained from find_symbol or " +
        "find_references (the 'usr' field on any result)."

    static let planRename = Tool(
        name: "plan_rename",
        description:
        "Build a semantic rename plan for a Swift/ObjC symbol. Returns every " +
            "reference site (including overrides) grouped by confidence tier: " +
            "green-indexstore for direct refs, yellow-disagreement for " +
            "operator/subscript/label cases whose range end cannot be verified " +
            "from the index alone, red-stale for files edited this session. " +
            "NEVER mutates files — the returned JSON plan is an input for a " +
            "subsequent sequence of Edit calls. Refuses on invalid identifiers, " +
            "SDK symbols, synthesized members, or when XCINDEX_DISABLE_PLAN_RENAME=1.",
        inputSchema: Schema.object(
            properties: [
                "usr": Schema.string(usrDescription),
                "newName": Schema.string(
                    "Proposed replacement identifier. Must be a valid Swift identifier: " +
                        "starts with a letter or underscore, contains only letters, digits, " +
                        "or underscores, and is not a Swift keyword."
                ),
                "projectPath": Schema.projectParams["projectPath"]!,
                "indexStorePath": Schema.projectParams["indexStorePath"]!,
            ],
            required: ["usr", "newName"]
        )
    )
}

// MARK: - Tool dispatch

enum Dispatcher {
    static func handle(
        name: String,
        arguments: [String: Value]?,
        processor: RequestProcessor
    ) async -> CallTool.Result {
        let args = arguments ?? [:]

        switch name {
        case "find_references":
            return await findReferences(args, processor)
        case "find_symbol":
            return await findSymbol(args, processor)
        case "find_definition":
            return await findDefinition(args, processor)
        case "find_overrides":
            return await findOverrides(args, processor)
        case "find_conformances":
            return await findConformances(args, processor)
        case "blast_radius":
            return await blastRadius(args, processor)
        case "status":
            return await status(args, processor)
        case "plan_rename":
            return await planRename(args, processor)
        default:
            return .init(content: [text("Unknown tool: \(name)")], isError: true)
        }
    }

    // MARK: find_references

    private static func findReferences(_ args: [String: Value], _ processor: RequestProcessor) async -> CallTool.Result {
        guard let symbolName = args["symbolName"]?.stringValue, !symbolName.isEmpty else {
            return error("find_references requires 'symbolName'")
        }
        let maxResults = args["maxResults"]?.intValue ?? 100
        let req = Request(
            op: "findRefs",
            projectPath: args["projectPath"]?.stringValue,
            indexStorePath: args["indexStorePath"]?.stringValue,
            symbolName: symbolName,
            usr: nil,
            filePath: nil
        )
        let resp = await processor.handle(req)
        if let err = resp.error {
            return error(err)
        }

        let occurrences = resp.occurrences ?? []
        let capped = Array(occurrences.prefix(maxResults))
        let truncated = occurrences.count > capped.count

        var lines: [String] = []
        if capped.isEmpty {
            lines.append("No references found for '\(symbolName)'.")
            lines.append("Check that the project has been built in Xcode and the symbol name is exact.")
        } else {
            let suffix = truncated ? " (showing first \(capped.count))" : ""
            lines.append("Found \(occurrences.count) reference(s) for '\(symbolName)'\(suffix):\n")
            for occ in capped {
                lines.append("  \(occ.path):\(occ.line):\(occ.column)  [\(occ.roles.joined(separator: ", "))]")
            }
            let involved = Array(Set(capped.map { $0.path }))
            if let note = Freshness.staleNote(involvedPaths: involved) {
                lines.append("\n⚠️  \(note)")
            }
            if truncated {
                lines.append("\nResults truncated. Increase maxResults to see all \(occurrences.count) occurrences.")
            }
        }
        return .init(content: [text(lines.joined(separator: "\n"))])
    }

    // MARK: find_symbol

    private static func findSymbol(_ args: [String: Value], _ processor: RequestProcessor) async -> CallTool.Result {
        guard let symbolName = args["symbolName"]?.stringValue, !symbolName.isEmpty else {
            return error("find_symbol requires 'symbolName'")
        }
        let req = Request(
            op: "findSymbol",
            projectPath: args["projectPath"]?.stringValue,
            indexStorePath: args["indexStorePath"]?.stringValue,
            symbolName: symbolName,
            usr: nil,
            filePath: nil
        )
        let resp = await processor.handle(req)
        if let err = resp.error {
            return error(err)
        }

        let symbols = resp.symbols ?? []
        if symbols.isEmpty {
            return .init(content: [text("No symbols found for '\(symbolName)'. Check the exact spelling and that the project has been built.")])
        }

        var lines = ["Found \(symbols.count) symbol(s) named '\(symbolName)':\n"]
        for s in symbols {
            lines.append("  USR:  \(s.usr)")
            lines.append("  Kind: \(s.kind)  Language: \(s.language)")
            if let path = s.definitionPath, let line = s.definitionLine {
                lines.append("  Defined at: \(path):\(line)")
            }
            lines.append("")
        }
        return .init(content: [text(lines.joined(separator: "\n"))])
    }

    // MARK: find_definition

    private static func findDefinition(_ args: [String: Value], _ processor: RequestProcessor) async -> CallTool.Result {
        guard let usr = args["usr"]?.stringValue, !usr.isEmpty else {
            return error("find_definition requires 'usr'")
        }
        let req = Request(
            op: "findDefinition",
            projectPath: args["projectPath"]?.stringValue,
            indexStorePath: args["indexStorePath"]?.stringValue,
            symbolName: nil,
            usr: usr,
            filePath: nil
        )
        let resp = await processor.handle(req)
        if let err = resp.error {
            return error(err)
        }
        let occurrences = resp.occurrences ?? []
        guard let occ = occurrences.first else {
            return .init(content: [text("No definition found for USR '\(usr)'.")])
        }
        let note = Freshness.staleNote(involvedPaths: [occ.path])
        let noteSuffix = note.map { "\n\n⚠️  \($0)" } ?? ""
        return .init(content: [text("\(occ.symbolName) defined at:\n  \(occ.path):\(occ.line):\(occ.column)\(noteSuffix)")])
    }

    // MARK: find_overrides

    private static func findOverrides(_ args: [String: Value], _ processor: RequestProcessor) async -> CallTool.Result {
        guard let usr = args["usr"]?.stringValue, !usr.isEmpty else {
            return error("find_overrides requires 'usr'")
        }
        let req = Request(
            op: "findOverrides",
            projectPath: args["projectPath"]?.stringValue,
            indexStorePath: args["indexStorePath"]?.stringValue,
            symbolName: nil,
            usr: usr,
            filePath: nil
        )
        let resp = await processor.handle(req)
        if let err = resp.error {
            return error(err)
        }
        let occurrences = resp.occurrences ?? []
        if occurrences.isEmpty {
            return .init(content: [text("No overrides found for USR '\(usr)'.")])
        }
        var lines = ["Found \(occurrences.count) override(s):\n"]
        for occ in occurrences {
            lines.append("  \(occ.path):\(occ.line)  (\(occ.symbolName))")
        }
        let involved = Array(Set(occurrences.map { $0.path }))
        if let note = Freshness.staleNote(involvedPaths: involved) {
            lines.append("\n⚠️  \(note)")
        }
        return .init(content: [text(lines.joined(separator: "\n"))])
    }

    // MARK: find_conformances

    private static func findConformances(_ args: [String: Value], _ processor: RequestProcessor) async -> CallTool.Result {
        guard let usr = args["usr"]?.stringValue, !usr.isEmpty else {
            return error("find_conformances requires 'usr'")
        }
        let req = Request(
            op: "findConformances",
            projectPath: args["projectPath"]?.stringValue,
            indexStorePath: args["indexStorePath"]?.stringValue,
            symbolName: nil,
            usr: usr,
            filePath: nil
        )
        let resp = await processor.handle(req)
        if let err = resp.error {
            return error(err)
        }
        let occurrences = resp.occurrences ?? []
        if occurrences.isEmpty {
            return .init(content: [text("No conformances found for USR '\(usr)'.")])
        }
        var lines = ["Found \(occurrences.count) conformance(s):\n"]
        for occ in occurrences {
            lines.append("  \(occ.symbolName)  at \(occ.path):\(occ.line)")
        }
        return .init(content: [text(lines.joined(separator: "\n"))])
    }

    // MARK: blast_radius

    private static func blastRadius(_ args: [String: Value], _ processor: RequestProcessor) async -> CallTool.Result {
        guard let filePath = args["filePath"]?.stringValue, !filePath.isEmpty else {
            return error("blast_radius requires 'filePath'")
        }
        let req = Request(
            op: "blastRadius",
            projectPath: args["projectPath"]?.stringValue,
            indexStorePath: args["indexStorePath"]?.stringValue,
            symbolName: nil,
            usr: nil,
            filePath: filePath
        )
        let resp = await processor.handle(req)
        if let err = resp.error {
            return error(err)
        }
        guard let br = resp.blastRadius else {
            return .init(content: [text("No blast radius data returned.")])
        }

        var lines: [String] = []
        let fileName = (filePath as NSString).lastPathComponent

        if br.affectedFiles.isEmpty {
            lines.append("No dependents found for '\(fileName)' — safe to edit in isolation.")
        } else {
            lines.append("Blast radius for '\(fileName)': \(br.affectedFiles.count) affected file(s)\n")
            lines.append("Direct dependents:")
            for f in br.directDependents { lines.append("  \(f)") }
            if !br.coveringTests.isEmpty {
                lines.append("\nCovering tests:")
                for f in br.coveringTests { lines.append("  \(f)") }
            }
            let directSet = Set(br.directDependents)
            let testsSet = Set(br.coveringTests)
            let others = br.affectedFiles.filter { !directSet.contains($0) && !testsSet.contains($0) }
            if !others.isEmpty {
                lines.append("\nTransitive dependents (\(others.count)):")
                for f in others.prefix(20) { lines.append("  \(f)") }
                if others.count > 20 {
                    lines.append("  … and \(others.count - 20) more")
                }
            }
        }

        if let note = Freshness.staleNote(involvedPaths: [filePath]) {
            lines.append("\n⚠️  \(note)")
        }

        return .init(content: [text(lines.joined(separator: "\n"))])
    }

    // MARK: status

    private static func status(_ args: [String: Value], _ processor: RequestProcessor) async -> CallTool.Result {
        let req = Request(
            op: "status",
            projectPath: args["projectPath"]?.stringValue,
            indexStorePath: args["indexStorePath"]?.stringValue,
            symbolName: nil,
            usr: nil,
            filePath: nil
        )
        let resp = await processor.handle(req)
        if let err = resp.error {
            return error(err)
        }
        guard let status = resp.status else {
            return .init(content: [text("No status data returned.")])
        }

        let editedFiles = Freshness.getEditedFiles().sorted()
        var lines: [String] = [
            "Index store: \(status.indexStorePath)",
            "Last updated: \(status.indexMtime ?? "unknown")",
        ]

        if !editedFiles.isEmpty {
            lines.append("\nFiles edited this session: \(editedFiles.count)")
            for f in editedFiles { lines.append("  \(f)") }
            lines.append("\n⚠️  These files were edited after the index was built. Consider rebuilding in Xcode for accurate results.")
        } else {
            lines.append("\nNo source files edited this session — index should be current.")
        }

        return .init(content: [text(lines.joined(separator: "\n"))])
    }

    // MARK: plan_rename

    /// Emits a pretty-printed JSON plan inside a ```json fence. A
    /// freshness warning appends below the fence when any range path
    /// was edited this session.
    private static func planRename(_ args: [String: Value], _ processor: RequestProcessor) async -> CallTool.Result {
        guard let usr = args["usr"]?.stringValue, !usr.isEmpty else {
            return error("plan_rename requires 'usr'")
        }
        guard let newName = args["newName"]?.stringValue, !newName.isEmpty else {
            return error("plan_rename requires 'newName'")
        }
        let req = Request(
            op: "planRename",
            projectPath: args["projectPath"]?.stringValue,
            indexStorePath: args["indexStorePath"]?.stringValue,
            usr: usr,
            newName: newName
        )
        let resp = await processor.handle(req)
        if let err = resp.error {
            return error(err)
        }
        guard let plan = resp.renamePlan else {
            return .init(content: [text("No plan returned.")])
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonString: String
        do {
            let data = try encoder.encode(plan)
            jsonString = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return self.error("Failed to encode rename plan: \(error.localizedDescription)")
        }

        var lines = ["```json", jsonString, "```"]
        let involved = Array(Set(plan.ranges.map { $0.path }))
        if let note = Freshness.staleNote(involvedPaths: involved) {
            lines.append("")
            lines.append("⚠️  \(note)")
        }
        return .init(content: [text(lines.joined(separator: "\n"))])
    }

    // MARK: helpers

    private static func text(_ s: String) -> Tool.Content {
        .text(text: s, annotations: nil, _meta: nil)
    }

    private static func error(_ message: String) -> CallTool.Result {
        .init(content: [text("Error: \(message)")], isError: true)
    }
}
