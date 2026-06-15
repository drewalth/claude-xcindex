![Hero](https://raw.githubusercontent.com/drewalth/claude-xcindex/main/assets/hero.png)

# xcindex

Semantic Swift/ObjC symbol lookups for Claude Code, powered by Xcode's
on-disk SourceKit index.

[![build](https://github.com/drewalth/claude-xcindex/actions/workflows/build.yml/badge.svg)](https://github.com/drewalth/claude-xcindex/actions/workflows/build.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-8A63D2)](https://claude.com/claude-code)

A [Claude Code](https://claude.com/claude-code) plugin that lets Claude
query Xcode's existing symbol index instead of falling back to `grep`.
References, overrides, conformances, and refactor impact analysis on
Swift/ObjC code hit the same `indexstore-db` library SourceKit-LSP uses —
USR-authoritative, sub-millisecond warm, no re-indexing.

It reads the index Xcode already writes to DerivedData during build. No
daemon, no second copy of your source, no builds on your behalf. It warns
when the index is stale rather than acting.

## Requirements

- macOS 14 (Sonoma) or later — `indexstore-db` requires macOS 14+.
- Xcode 16 or later with command-line tools (`xcode-select --install`).
- [Claude Code](https://claude.com/claude-code).
- An Xcode project (`.xcodeproj` / `.xcworkspace`) built at least once.

## Install

```
claude plugin marketplace add anthropics/claude-plugins-community
claude plugin install claude-xcindex@claude-community
```

First run downloads the matching `xcindex` binary from the GitHub release
and caches it under the plugin directory — no `npm install`, no manual
build.

Then, in a Swift project:

```
/xcindex-setup
```

This confirms the binary is ready, locates your Xcode project, and — with
your confirmation — runs `xcodebuild` per scheme so the index is populated.
Skip it if you build in Xcode yourself.

Verify with `/plugin` and `/xcindex-status`. If anything looks off, run
`./bin/xcindex-doctor`.

<details>
<summary>Install from a local clone</summary>

Useful for pinning to a specific commit or hacking on the plugin:

```sh
git clone https://github.com/drewalth/claude-xcindex.git
cd claude-xcindex/service && swift build -c release
```

Then in Claude Code:

```
/plugin marketplace add /absolute/path/to/claude-xcindex
/plugin install xcindex@xcindex-local
```

The launcher detects the from-source build at
`service/.build/release/xcindex` and symlinks it instead of downloading.
</details>

## Usage

The skills trigger automatically based on what you ask — no special syntax.

- "Where is `UserService` used?"
- "What calls `fetchUser`?"
- "What depends on `NetworkClient.swift`?"
- "What will break if I change `AuthManager`?"
- "Rename `fetchUser` to `loadUser` across the codebase."
- "What tests cover `ModelData.swift`?"

```
You: Find all callers of fetchUser.
Claude: [mcp__xcindex__find_symbol → mcp__xcindex__find_references]
        → 6 call sites across 4 files. Reads ±10 lines around each.
        Returns a focused summary instead of 8 full-file reads.
```

`/xcindex-status` checks index freshness and reports which files have been
edited since the last build.

### Tips

- **Build first.** The index only updates when you build. After a large
  edit, rebuild in Xcode (or via `/xcindex-setup`) before asking for
  references — stale results are annotated, not silently wrong.
- **Lead with the symbol.** "Where is `X` used" beats "find usages of the
  thing that fetches users" — name lookups disambiguate, USR lookups are
  authoritative.
- **Use it for renames.** Rename requests delegate to a subagent with
  isolated context, so large renames don't bloat your main session.

## MCP tools

Exposed under `mcp__xcindex__*`. Signatures and examples in
[docs/tools-reference.md](docs/tools-reference.md).

| Tool | Purpose |
|---|---|
| `find_symbol` | Name → candidate USRs with kind and defining file. |
| `find_references` | Every occurrence with file, line, column, role. |
| `find_definition` | The canonical definition site. |
| `find_overrides` | All overriding implementations of a method. |
| `find_conformances` | All types conforming to a protocol. |
| `blast_radius` | Minimal set of files affected by editing a file. |
| `status` | Index freshness, DerivedData path, last-build timestamp. |
| `plan_rename` | Semantic rename plan tiered by confidence — see [docs/tools-reference.md](docs/tools-reference.md#tiers) for tier definitions, or [docs/coverage.md](docs/coverage.md) for what each pinned fixture surfaces. |

## Skills & hooks

- **`swift-refactor-plan`** — triggers on "plan a rename / what would changing X involve?". Produces a written refactor plan (sites, risks, recommended execution path) without making any edits.
- **`swift-find-references`** — triggers on "where is X used?". Steers Claude off grep.
- **`swift-blast-radius`** — triggers on "what does this file affect?". Skips shotgun reads.
- **`swift-rename-symbol`** — triggers on committed rename requests. Delegates to a subagent so the main context doesn't balloon.
- **`SessionStart` hook** — reports index freshness up front.
- **`PostToolUse` hook** (Edit/Write/MultiEdit) — tracks Swift/ObjC edits so stale results are annotated. Never triggers a build.
- **`PreToolUse` hook** (Grep) — when Claude is about to grep Swift/ObjC source (`*.swift`/`*.m`/`*.mm` glob, `type: swift`, or a Swift file path), injects a one-line reminder that the semantic xcindex tools and skills exist. Non-blocking — the Grep proceeds either way; free-text searches (TODOs, log messages) are unaffected.

## Troubleshooting

Run `./bin/xcindex-doctor` — it checks Xcode, `libIndexStore`, the cached
binary, and index freshness line-by-line with remediation hints. Full
catalogue in [docs/troubleshooting.md](docs/troubleshooting.md).

## Development

```sh
make build-debug    # debug build
make test           # run tests
make help           # list all dev targets
```

```
claude-xcindex/
├── .claude-plugin/plugin.json     # plugin manifest
├── .mcp.json                      # MCP server registration
├── bin/run                        # launcher
├── service/                       # Swift MCP server
├── skills/                        # refactor-plan, find-refs, blast-radius, rename
├── agents/swift-refactor-specialist.md
├── commands/                      # /xcindex-setup, /xcindex-status
├── hooks/                         # session-start.sh, post-edit.sh, pre-grep.sh
├── scripts/                       # dev-only: build.sh, fixtures, benchmarks
└── Makefile                       # dev task runner (build, test, lint, format)
```

PRs welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md). Please open an
issue to discuss architectural changes first.

---

## Why it's faster than grep

Claude's default answer to "where is `UserService` used?" is `ripgrep` —
40 noisy textual matches, 8 full files read to disambiguate. Expensive in
tokens, imprecise in results. Xcode already solved this: every build
writes a full semantic index to DerivedData, and Apple's
[`indexstore-db`](https://github.com/swiftlang/indexstore-db) queries it.
This plugin wraps those queries behind MCP tools so Claude reads only the
lines that matter.

- **~200× faster than `grep -rn`** on the same source tree, sub-millisecond
  on warm queries.
- **Semantic, not textual** — finds protocol witnesses, extensions, `@objc`
  bridging, and module-scoped name collisions that `grep` can't.
- **Up to 70% fewer files read** to answer a reference query.

Full numbers and methodology in [docs/benchmarks.md](docs/benchmarks.md);
the mental model (freshness, DerivedData resolution, USR-first lookups) in
[docs/how-it-works.md](docs/how-it-works.md).

## Architecture

```
Claude Code
    ↓ (MCP over stdio)
xcindex plugin
├── Skills          — tell Claude WHEN to use the index
├── Hooks           — freshness warnings + nudge Claude off grep on Swift code
├── Subagent        — isolated context for large renames
├── Slash commands  — /xcindex-setup, /xcindex-status
└── Swift binary    — MCP server, queries IndexStoreDB
    ↓ (reads LMDB)
DerivedData/Index.noindex/DataStore
    ↑ (writes during build)
Xcode
```

One native Swift binary, speaking MCP directly via Anthropic's
[Swift SDK](https://github.com/modelcontextprotocol/swift-sdk). No Node
runtime, no intermediate process.

## Complementary tools

This plugin focuses on **semantic queries** over Xcode's on-disk index.
It is not a language server and does not build, test, or run your
project. Pair it with:

### Anthropic's [`swift-lsp`](https://claude.com/plugins/swift-lsp)

Live LSP features (completion, diagnostics, hover) backed by
SourceKit-LSP. Different layer: `swift-lsp` is an editor-UI integration
(no MCP tools the agent can call); `xcindex` exposes semantic queries to
the agent loop. They don't overlap.

| | `swift-lsp` | `xcindex` |
|---|---|---|
| Backend | SourceKit-LSP server | `indexstore-db` reader |
| Source of truth | live Swift source | Xcode build-time index |
| Requires Xcode build? | No | Yes (once) |
| Diagnostics & completion | Yes | No |
| Hover / jump-to-definition | Yes | Definition only |
| Agent-callable MCP tools | No (editor-UI only) | 7 tools |
| Overrides / conformances / blast-radius | Not first-class | Yes |
| Works on Linux / SwiftPM-only | Yes | No (DerivedData-specific) |
| Warm query latency | LSP round-trip | sub-millisecond |
| Freshness model | always live | hook-warned when stale |

### Build & test orchestration

- Apple's [`mcpbridge`](https://developer.apple.com/documentation/xcode) (ships with Xcode 26.3+) for build, test, preview, docs.
- [`XcodeBuildMCP`](https://github.com/cameroncooke/XcodeBuildMCP) for older Xcode versions.

## Other Swift symbol tools

Where `xcindex` sits relative to the closest neighbours:

| | `xcindex` | [`block/xcode-index-mcp`](https://github.com/block/xcode-index-mcp) | [SwiftLens](https://github.com/swiftlens/swiftlens) |
|---|---|---|---|
| Backend | `indexstore-db` (direct) | `indexstore-db` (direct) | SourceKit-LSP |
| Packaging | Claude Code plugin (skills + hooks + subagent) | Raw MCP server | Raw MCP server |
| Runtime | Native Swift binary | Python (`uv`) + Swift service | Python 3.10+ |
| MCP tools | 7 (find_symbol, find_references, find_definition, find_overrides, find_conformances, blast_radius, status) | 4 (load_index, symbol_occurrences, get_occurrences, search_pattern) | 15 (single-file analysis + cross-file refs/defs) |
| Overrides / conformances | Yes | No | No |
| Blast-radius analysis | Yes | No | No |
| Freshness warnings | Hook-driven, per-session | None | None |
| Status (Apr 2026) | Active | Active (~55⭐) | **Archived 2026-03-10** |

`block/xcode-index-mcp` is the closest prior art — same backend, narrower
tool surface, no plugin packaging. SwiftLens covered the same niche from
the SourceKit-LSP angle but [was archived in March 2026](https://github.com/swiftlens/swiftlens).

## Prior art

- [`apple/indexstore-db`](https://github.com/swiftlang/indexstore-db) — the query library this plugin wraps.
- [`block/xcode-index-mcp`](https://github.com/block/xcode-index-mcp) — closest prior art, Python + Swift MCP server for Goose/Cursor.
- [`michaelversus/SwiftFindRefs`](https://github.com/michaelversus/SwiftFindRefs) — CLI with the same core query.

## Privacy

Runs entirely on your local machine. No telemetry, no analytics, no
tracking. The only network request is to GitHub to download the prebuilt
binary on first run. All queries run locally against Xcode's on-disk
index.

## License

MIT — see [LICENSE](./LICENSE).
