# claude-xcindex — Plan

A Claude Code plugin that gives Claude surgical access to Xcode's pre-built symbol index, so Swift/ObjC refactors and navigation cost far fewer tokens than `grep`-and-read-file workflows.

---

## TL;DR

Xcode already indexes every Swift/ObjC symbol in your project and stores that index on disk under `DerivedData/Index.noindex/DataStore/`. Apple ships `IndexStoreDB`, a Swift library that queries this index (it's what SourceKit-LSP uses). By exposing a small, semantic set of index queries through an MCP server and packaging it as a Claude Code plugin — with skills that teach Claude when to prefer the index over `grep`, and hooks that warn when the index is stale — we can cut the token cost of refactors, reference lookups, and "what depends on this?" queries substantially. The mechanism mirrors what code-review-graph does with Tree-sitter, but uses a richer, already-maintained semantic index instead of building our own.

## Why this works

- **Xcode's index is queryable.** `~/Library/Developer/Xcode/DerivedData/<Project>/Index.noindex/DataStore/` contains the index-while-building output. Apple's [`indexstore-db`](https://github.com/swiftlang/indexstore-db) exposes symbol/occurrence/relation queries over it via an LMDB-backed Swift API.
- **There's precedent.** [`block/xcode-index-mcp`](https://github.com/block/xcode-index-mcp) already wraps IndexStoreDB behind MCP for Goose/Cursor, and [`SwiftFindRefs`](https://github.com/michaelversus/SwiftFindRefs) is a CLI that does the same for AI refactoring workflows. Block's project is Python + Swift subprocess; we're doing TypeScript + Swift subprocess to fit the Claude Code plugin ecosystem.
- **Xcode 26.3's built-in MCP (`mcpbridge`) is complementary, not competitive.** Apple's MCP focuses on build/test/preview/documentation. It does not expose raw IndexStoreDB queries. Users should install both: `mcpbridge` for build orchestration, `claude-xcindex` for semantic symbol queries.
- **The token savings come from replacing shotgun reads with surgical reads.** Today: Claude runs `rg "MyViewController"`, gets 40 noisy textual matches, and reads 8 full files. With IndexStoreDB: Claude asks for reference sites of a specific USR, gets 6 exact file+line locations, and reads only those excerpts. Swift-specific semantic resolution (protocol witnesses, extensions, @objc bridging, overrides) is strictly better than Tree-sitter on Swift.

## Architecture

```
Claude Code
    ↓ (MCP over stdio)
claude-xcindex plugin
├── Skills          — tell Claude WHEN to use the index
├── Hooks           — freshness checks, guardrails
├── MCP server (TS) — tool registration, schema, error handling
└── Swift service   — spawned subprocess, queries IndexStoreDB
    ↓ (reads LMDB)
DerivedData/Index.noindex/DataStore
    ↑ (writes during build)
Xcode
```

Claude Code only talks to the MCP server. The MCP server spawns a Swift CLI subprocess and communicates with it over its own stdio JSON-RPC. All MCP schema, description text, freshness logic, and error handling lives in TypeScript. The Swift binary stays tiny — just a request/response loop that accepts operations like `{"op":"findRefs","usr":"..."}` and emits JSON back.

## Repo layout

```
claude-xcindex/
├── .claude-plugin/
│   └── plugin.json
├── mcp/
│   ├── package.json
│   ├── src/
│   │   ├── server.ts            # MCP server, tool registrations
│   │   ├── swift-bridge.ts      # spawn + JSON-RPC to Swift binary
│   │   └── freshness.ts         # stale-index detection
│   └── swift-service/
│       ├── Package.swift        # depends on apple/indexstore-db
│       └── Sources/xcindex/
│           ├── main.swift       # stdio JSON-RPC loop
│           └── Queries.swift    # IndexStoreDB queries
├── skills/
│   ├── swift-find-references/SKILL.md
│   ├── swift-blast-radius/SKILL.md
│   └── swift-rename-symbol/SKILL.md
├── hooks/
│   ├── session-start.sh
│   └── post-edit.sh
├── agents/
│   └── swift-refactor-specialist.md
├── commands/
│   └── xcindex-status.md
├── README.md
└── LICENSE
```

## MCP tool surface

Keep this small and semantic. Each tool answers a question Claude actually needs to ask. Paginate or cap results — `find_references` on a popular symbol can return thousands of hits.

| Tool | Purpose |
|---|---|
| `xcindex_find_symbol` | Given a name, return candidate USRs with kind (class/func/protocol) and defining file. Disambiguation step. |
| `xcindex_find_references` | Given a USR, return every occurrence with file, line, column, and role (call/read/write/override). |
| `xcindex_find_definition` | Given a USR, return the canonical definition site. |
| `xcindex_find_overrides` | Given a method USR, return all overriding implementations. Swift-specific killer feature. |
| `xcindex_find_conformances` | Given a protocol USR, return all types that conform. |
| `xcindex_blast_radius` | Given a file path, return the minimal set of files affected by editing it (transitive callers + covering tests). The token-saving query. |
| `xcindex_status` | Return index freshness, last-build timestamp, DerivedData path, and whether any source files have mtime newer than the index. |

## Skills

Skills are where token reduction actually happens — an MCP tool that's never called is worthless. The `description` frontmatter is what Claude scans when deciding whether to load the skill; write it for the trigger, not for documentation.

### `skills/swift-find-references/SKILL.md`

```markdown
---
name: swift-find-references
description: Use BEFORE running grep or ripgrep on .swift files when the user
  asks about usages, callers, references, or impact of a Swift symbol. Also use
  before reading files to understand a rename or signature change. Uses Xcode's
  pre-built index for semantic (not textual) matching — no false positives from
  comments, strings, or similarly-named symbols in other modules.
---

# When to use

- "Where is X called?" / "What uses X?" / "Find all references to X"
- Before editing a public API to estimate impact
- Before renaming a symbol
- Before reading through files to trace a call chain

# When NOT to use

- The symbol is local to one file (read the file directly)
- The user is asking about a string literal or comment (grep is right)
- `xcindex_status` reports the index is stale and the user hasn't built recently

# How to use

1. Call `xcindex_find_symbol` with the name to get candidate USRs.
2. If multiple candidates, disambiguate by kind and file path before proceeding.
3. Call `xcindex_find_references` with the chosen USR.
4. Read only the files that appear in the results, and only the lines near the
   reported occurrences — not the full files.
```

### `skills/swift-blast-radius/SKILL.md`

Trigger: the user is about to edit a file or has asked "what depends on this?" Claude calls `xcindex_blast_radius` to get the minimal read set before reading files.

### `skills/swift-rename-symbol/SKILL.md`

Trigger: explicit rename request. Workflow: `find_symbol` → `find_references` → edit each site. Delegates to the `swift-refactor-specialist` subagent so the main context doesn't fill with 50 file reads.

## Hooks

The index lies when the user hasn't built recently. Two hooks handle this without being invasive.

**SessionStart** — run `xcindex_status`, and if the index is stale or missing, inject a ~50-token note into session context: "The Xcode index for this project was last updated 4 hours ago; 12 Swift files have been edited since. Consider building before asking about cross-file references, or expect stale results." Don't fail the session — just warn.

**PostToolUse on Edit|Write** — when Claude edits a `.swift` file, mark the index as potentially stale for that file in plugin state. MCP tool responses then annotate: "Note: `UserService.swift` was edited this session after the index was built; results for symbols in that file may be stale."

Do NOT auto-trigger `xcodebuild`. Builds are slow, destructive to the user's Xcode state, and surprising. Warn, don't act.

## Subagent: `swift-refactor-specialist`

One subagent, focused scope, restricted tools. Gets its own context window, the `xcindex_*` tools plus Read/Edit, and a tight system prompt. The main session delegates to it for renames and signature changes, then gets back a short summary instead of 50 file reads in its own context.

## `plugin.json` skeleton

```json
{
  "name": "claude-xcindex",
  "version": "0.1.0",
  "description": "Query Xcode's pre-built symbol index from Claude Code.",
  "mcp_servers": {
    "xcindex": {
      "command": "node",
      "args": ["${plugin_dir}/mcp/dist/server.js"]
    }
  },
  "hooks": {
    "SessionStart": {
      "command": "bash ${plugin_dir}/hooks/session-start.sh"
    },
    "PostToolUse": {
      "matcher": "Edit|Write",
      "command": "bash ${plugin_dir}/hooks/post-edit.sh"
    }
  },
  "skills": ["./skills/*"],
  "agents": ["./agents/*"]
}
```

Verify against the current plugin schema at build time — this area is evolving.

## Open design questions to resolve early

1. **DerivedData discovery.** Default is `~/Library/Developer/Xcode/DerivedData/<Project>-<hash>/`, but users can redirect it via Xcode preferences. Options: filesystem scan (Block's approach, brittle but works), require a config field, or probe `xcodebuild -showBuildSettings`. Likely start with scan + config override.
2. **SPM projects.** Pure SPM built via CLI with `-index-store-path` produces the same index format at a different location. Support in v1 or defer?
3. **Multi-project workspaces.** If the user has multiple `.xcodeproj` in one repo, which index wins? Probably match against `cwd` + scan `DerivedData` for the matching name, with a `.xcindex.json` override at repo root.
4. **Interop with `mcpbridge`.** Xcode 26.3's official MCP handles builds/tests/previews. Document the recommended setup as "install both" rather than taking a dependency.
5. **Caching.** IndexStoreDB is LMDB-backed and already fast. USR→display-name formatting has some cost. Don't cache until measured.

## Suggested implementation order

A pragmatic v0 → v1 sequence. Each step should be independently useful.

1. **Bootstrap the Swift service.** `swift package init --type executable`. Add `apple/indexstore-db` as a dependency. Implement one op: `{"op":"findRefs","projectPath":"...","symbolName":"..."}`. Return JSON. Test manually with `echo '...' | swift run xcindex`.
2. **Add DerivedData discovery.** Given a project path, find the matching DerivedData folder. Mirror Block's approach.
3. **TS MCP server skeleton.** Use `@modelcontextprotocol/sdk`. Register one tool: `xcindex_find_references`. Spawn the Swift binary, pipe JSON, return results. Confirm it works via MCP Inspector before adding more tools.
4. **Expand tool surface incrementally.** Add `find_symbol` next (needed for disambiguation), then `find_definition`, `find_overrides`, `find_conformances`, `status`. Save `blast_radius` for last — it's the compound query.
5. **Wire as a Claude Code plugin.** Write `plugin.json`. Install locally with `/plugin marketplace add <path>` / `/plugin install claude-xcindex`. Verify `/plugin` shows it and tools appear.
6. **Write the `swift-find-references` skill.** Iterate on the `description` until Claude triggers it reliably when the user says "find usages of X" without mentioning the tool by name.
7. **Add SessionStart hook with freshness check.** Reuse `xcindex_status`.
8. **Add the remaining skills** (`blast-radius`, `rename-symbol`) and the subagent.
9. **Benchmark.** Pick a real refactor task on a real iOS project. Run it with and without the plugin. Measure tokens on both. Target: 3–8× reduction on reference-heavy workflows, consistent with what code-review-graph reports.
10. **Package and publish** to the Claude Code plugin marketplace.

## Prior art and references

- [`apple/indexstore-db`](https://github.com/swiftlang/indexstore-db) — Apple's Swift library for querying index-store data. The query primitive.
- [`MobileNativeFoundation/swift-index-store`](https://github.com/MobileNativeFoundation/swift-index-store) — alternative thin Swift wrapper over `libIndexStore`. Lower-level; use indexstore-db unless there's a reason not to.
- [`block/xcode-index-mcp`](https://github.com/block/xcode-index-mcp) — Python + Swift MCP server for Goose/Cursor. Closest prior art; steal the DerivedData-resolution logic.
- [`michaelversus/SwiftFindRefs`](https://github.com/michaelversus/SwiftFindRefs) — CLI with the same core query, narrower scope, explicitly pitched for AI workflows.
- [`tirth8205/code-review-graph`](https://github.com/tirth8205/code-review-graph) — Tree-sitter-based equivalent for language-agnostic projects. Useful for blast-radius algorithm reference.
- [`cameroncooke/XcodeBuildMCP`](https://github.com/cameroncooke/XcodeBuildMCP) — MCP for Xcode build/test/simulator operations. Complementary to this plugin.
- Xcode 26.3's built-in MCP via `xcrun mcpbridge` — Apple-native build/test/documentation tools. Install alongside.
- "Adding Index-While-Building and Refactoring to Clang" (LLVM talk) — background on the index data model.

## Notes for the Claude Code session that picks this up

This plan is the full context for the project. Start at step 1 of the implementation order. When in doubt about the MCP plugin schema or Claude Code plugin layout, consult the current Anthropic docs rather than guessing — this area has been evolving. When implementing the Swift service, read Block's `xcode-index-mcp` Swift source first; it solved the DerivedData resolution and basic IndexStoreDB query patterns already.

Ask before making architectural changes to the plan (language choice, tool surface, subprocess boundary). Smaller choices — file names, internal JSON-RPC shape, error message wording — decide freely.
