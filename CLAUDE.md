# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Claude Code plugin that wraps Xcode's pre-built SourceKit symbol index
(`indexstore-db`) as MCP tools so Claude can do semantic Swift/ObjC symbol
lookups instead of textual `grep`. Ships an MCP server, skills, hooks, a
subagent, and a slash command. See `README.md` for user-facing docs.

## Build & run

```sh
./build.sh                         # release build
./build.sh --debug                 # debug build

cd service && swift build -c release
cd service && swift test
cd service && swift test --filter xcindexTests.example   # single test
```

`build.sh` just wraps `swift build -c release` in the `service/` directory.
Re-run after `git pull`. The binary Claude Code launches is
`service/.build/release/xcindex`.

## Architecture

Single Swift binary. Claude Code spawns `service/.build/release/xcindex`
directly via `.mcp.json`; the binary speaks MCP over stdio using the
official [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk).

```
Claude Code ──MCP/stdio──▶ xcindex (Swift) ──▶ IndexStoreDB
```

The source tree:

- `service/Sources/xcindex/main.swift` — starts the MCP `Server` with a
  `StdioTransport` and parks on `waitUntilCompleted()`.
- `service/Sources/xcindex/MCPServer.swift` — tool registration (schemas,
  descriptions) and the `CallTool` dispatcher that formats text output.
  All user-visible strings live here.
- `service/Sources/xcindex/RequestProcessor.swift` — an actor that caches
  `IndexQuerier` instances by store path and routes internal ops.
- `service/Sources/xcindex/Queries.swift` — the actual IndexStoreDB queries.
- `service/Sources/xcindex/Freshness.swift` — session-edited-file tracking
  shared with the bash hooks via a state file in `$TMPDIR`.
- `service/Sources/xcindex/DerivedData.swift` — resolves the IndexStore
  DataStore path from a project path.
- `service/Sources/xcindex/Models.swift` — internal wire types used by
  `RequestProcessor` (not MCP-visible).

When adding a tool: register it in `ToolDefinitions.all` (MCPServer.swift),
add a dispatch case in `Dispatcher.handle`, add a `handle<Op>` method on
`RequestProcessor`, add a query method on `IndexQuerier`.

### Contracts that must stay in sync

- **Session state file path** is derived in *three* places and must match
  byte-for-byte: `service/Sources/xcindex/Freshness.swift#stateFilePath`,
  `hooks/session-start.sh`, `hooks/post-edit.sh`. Format:
  `$TMPDIR/xcindex-edited-<sha1(cwd) first 12 chars>.txt`, one absolute path
  per line. `CLAUDE_PROJECT_DIR` overrides `cwd` in all three.
- **Op dispatch**: each `op` string in `Request` (Models.swift) must have a
  matching case in `RequestProcessor.handle` and a corresponding MCP tool in
  `ToolDefinitions.all`.

### Concurrency

`Server.start(transport:)` spawns a detached task that handles MCP requests
concurrently. Tool handlers run in parallel tasks. `RequestProcessor` is an
actor so the `querierCache` is race-free; each `IndexQuerier` is reached
only through the actor, which keeps IndexStoreDB access serialized per store
path.

### Freshness model

The index only updates when the user builds in Xcode. Claude editing files
invalidates it. We track this without triggering builds:

- `SessionStart` hook truncates the state file and prints a freshness note.
- `PostToolUse` hook on `Edit|Write|MultiEdit` appends edited Swift/ObjC paths
  to the state file.
- Every MCP tool response calls `Freshness.staleNote(involvedPaths:)` and
  appends a warning if any returned path was edited this session.

Hooks **warn, never act** — no automatic builds. This is deliberate.

### DerivedData resolution

`DerivedDataLocator` (Swift) handles: explicit `indexStorePath`, custom
`IDECustomDerivedDataLocation` from Xcode defaults, or scanning
`~/Library/Developer/Xcode/DerivedData/` for `<ProjectName>-*` and picking the
most recently modified. `hooks/session-start.sh` mirrors the same logic in
bash so the hook can warn before any MCP call.

## Plugin packaging

- `.claude-plugin/plugin.json` — plugin manifest (name, version, description).
- `.mcp.json` — MCP server registration; uses `${CLAUDE_PLUGIN_ROOT}` so paths
  resolve wherever Claude Code installs the plugin.
- `hooks/hooks.json` — declares the `SessionStart` and `PostToolUse` hooks.
- `skills/*/SKILL.md` — frontmatter `description` is what Claude scans to
  decide whether to load a skill; this is the load-bearing trigger, not the
  body.
- `agents/swift-refactor-specialist.md` — subagent for large renames, with an
  explicit `tools:` allowlist. Main session delegates here so rename work
  doesn't balloon the parent context.
- `commands/xcindex-status.md` — `/xcindex-status` slash command.

## Conventions

- Tools are exposed under the `mcp__xcindex__*` namespace (auto-prefixed by
  Claude Code from the server key in `.mcp.json`).
- Always do `find_symbol` → get USR → `find_references`/`find_definition`/
  `find_overrides`/`find_conformances`. Name-based lookups are for
  disambiguation; USR-based lookups are the authoritative ones.
- Keep tool text formatting in `MCPServer.swift` (the `Dispatcher` enum).
  `RequestProcessor` and `Queries` should return structured data, not
  user-facing strings.
