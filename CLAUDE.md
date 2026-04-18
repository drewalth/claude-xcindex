# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Claude Code plugin that wraps Xcode's pre-built SourceKit symbol index
(`indexstore-db`) as MCP tools so Claude can do semantic Swift/ObjC symbol
lookups instead of textual `grep`. Ships an MCP server, skills, hooks, a
subagent, and a slash command. See `README.md` for user-facing docs.

## Build & run

```sh
./build.sh                         # release build of both layers
./build.sh --debug                 # debug build of both layers

cd mcp && npm run build            # TypeScript only
cd mcp && npm run dev              # TypeScript watch mode
cd mcp/swift-service && swift build -c release
cd mcp/swift-service && swift test
cd mcp/swift-service && swift test --filter xcindexTests.example   # single test
```

`build.sh` is the entry point — it runs `npm install && npm run build` for the
Node server and `swift build -c release` for the Swift binary, then smoke-tests
the binary with a JSON-RPC `status` request. Re-run it after `git pull`.

Outputs that must exist for the plugin to work:
- `mcp/dist/server.js` (Node MCP server — the one Claude Code connects to)
- `mcp/swift-service/.build/release/xcindex` (Swift subprocess; `SwiftBridge`
  falls back to `.build/debug/xcindex` if release is missing)

## Architecture

Two-layer pipeline. Claude Code talks **only** to the Node MCP server; the
Node server owns the tool schema and spawns the Swift binary as a child
process, communicating over newline-delimited JSON over stdio.

```
Claude Code ──MCP/stdio──▶ mcp/dist/server.js ──JSON/stdio──▶ xcindex (Swift) ──▶ IndexStoreDB
```

**Intentional asymmetry**: all MCP schema, tool descriptions, freshness
annotation, error formatting, and user-facing strings live in TypeScript
(`mcp/src/server.ts`). The Swift binary stays deliberately small — just a
stdio read loop (`main.swift`) → `RequestProcessor` → `IndexQuerier`. When
adding a tool, you extend both layers but the user-visible surface belongs in
TS.

### Contracts that must stay in sync

- **Wire types**: `mcp/src/swift-bridge.ts` (`SwiftRequest`/`SwiftResponse`)
  must match `mcp/swift-service/Sources/xcindex/Models.swift`. Adding a field
  requires touching both.
- **Op dispatch**: each `op` string in `SwiftRequest` must have a matching
  case in `RequestProcessor.handle`.
- **Session state file path** is derived in *three* places and must match
  byte-for-byte: `mcp/src/freshness.ts#stateFilePath`,
  `hooks/session-start.sh`, `hooks/post-edit.sh`. Format:
  `$TMPDIR/xcindex-edited-<sha1(cwd) first 12 chars>.txt`, one absolute path
  per line. `CLAUDE_PROJECT_DIR` overrides `cwd` in all three.

### Swift subprocess model

`SwiftBridge` keeps one persistent Swift process per MCP server instance.
`IndexQuerier` caches an open `IndexStoreDB` handle per store path, so repeat
queries don't re-open the database. A FIFO promise chain in `SwiftBridge.send`
serializes requests — the line-oriented protocol would desync if two callers
wrote concurrently to stdin. If the subprocess dies, pending resolvers are
drained with an error and the next `send` respawns it.

### Freshness model

The index only updates when the user builds in Xcode. Claude editing files
invalidates it. We track this without triggering builds:

- `SessionStart` hook truncates the state file and prints a freshness note.
- `PostToolUse` hook on `Edit|Write|MultiEdit` appends edited Swift/ObjC paths
  to the state file.
- Every MCP tool response calls `staleNote(paths)` and appends a warning if
  any returned path was edited this session.

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
  Claude Code from the server name in `.mcp.json`).
- Always do `find_symbol` → get USR → `find_references`/`find_definition`/
  `find_overrides`/`find_conformances`. Name-based lookups are for
  disambiguation; USR-based lookups are the authoritative ones.
- Keep the Swift binary's surface minimal. If you're tempted to add formatting
  or user-facing strings to Swift, put them in TypeScript instead.
