![Hero](https://raw.githubusercontent.com/drewalth/claude-xcindex/main/assets/hero.png)

#### An MCP bridge to Xcode's SourceKit symbol index for Claude Code. USR-based references, overrides, conformances, and blast-radius queries via `indexstore-db` — the same library SourceKit-LSP uses.

[![build](https://github.com/drewalth/claude-xcindex/actions/workflows/build.yml/badge.svg)](https://github.com/drewalth/claude-xcindex/actions/workflows/build.yml)

---

A [Claude Code](https://claude.com/claude-code) plugin that gives Claude
semantic access to Xcode's on-disk symbol index so refactors, reference
lookups, and impact analysis on Swift/ObjC projects don't fall back to
`grep`-and-read-file.

- **Sub-millisecond** semantic queries after the first call in a session — roughly **200× faster than `grep`** on the same source tree.
- **Up to 70% fewer files** to read vs `grep` on a 43k-LOC project, because results are precise `(file, line, column, role)` tuples instead of textual matches.
- Finds what `grep` can't — protocol witnesses, extensions, overrides, `@objc` bridging, module-scoped name collisions.
- **Zero re-indexing.** Reads the same `IndexStoreDB` Xcode writes to `DerivedData/…/Index.noindex/` during build. No daemon, no second copy of your codebase.
- **Freshness-aware.** Annotates results in files Claude edited this session; warns at session start if the index is older than your source. Never triggers a build on your behalf.

---

## Features

### Lightning fast

After the first call in a session opens the on-disk index, every subsequent
query returns in **under a millisecond** — reference lookups, definition
jumps, override and conformance searches alike. On a 43k-LOC Swift project,
that's roughly **200× faster** than the equivalent `grep -rn` over the
same source tree. The only outlier is `blast_radius`, which traverses the
dependency graph and lands around 900 ms warm.

### Semantic, not textual

`grep` can't tell `Gauge` the type from `gauge` the local variable from
`Gauge` in a string literal. SourceKit's index can. Every result comes back
with a USR (unique symbol resolver), a kind (class / protocol / method /
property), a role (call / read / write / override), and exact
file / line / column — so Claude reads only the lines that matter instead
of opening eight files to disambiguate. On the benchmark project, a typical
"where is X used?" query returns up to **70% fewer files** to read.

### Honest about freshness

The index only refreshes when you build in Xcode. A `SessionStart` hook
warns up front if source files are newer than the index. A `PostToolUse`
hook tracks every Swift/ObjC file Claude edits during the session, and MCP
tool responses annotate any returned path that's been edited locally. The
plugin never triggers a build on your behalf — it warns, you decide.

## Benchmarks

> Sub-millisecond warm queries, ~200× faster than `grep`, reading up to
> 70% fewer files. Measured on a real-world Swift project, MacBook Pro M3,
> median of 5 runs. Reproducible: `scripts/benchmark.py /path/to/Project.xcodeproj`.

**Project:** a real-world Swift project — 302 Swift files, 43,185 LOC, 222 MB on-disk index.

### Tool latency

| Tool | Cold (ms) | Warm (ms) |
|---|---:|---:|
| `find_symbol` | 5446 | 0 |
| `find_references` | 5496 | 1 |
| `find_definition` | — | 0 |
| `find_overrides` | — | 0 |
| `find_conformances` | — | 0 |
| `blast_radius` | 6377 | 876 |
| `status` | 5545 | 0 |

_Cold = first query in a fresh subprocess (includes opening the LMDB index).
Warm = subsequent query in the same process — what Claude experiences after
the first call in a session, since the MCP server keeps the Swift subprocess
alive. USR-based tools (`find_definition` / `find_overrides` /
`find_conformances`) only run after a `find_symbol` resolves the USR, so
cold timing is N/A._

### Precision: xcindex vs `grep -rn '\bSym\b'`

| Symbol | Kind | grep hits | grep files | xcindex refs | xcindex files | files saved | grep ms | xcindex warm ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `A` | common domain struct | 129 | 45 | 95 | 27 | 18 (40%) | 228 | 12 |
| `B` | service protocol | 90 | 27 | 18 | 8 | 19 (70%) | 230 | 0 |
| `C` | service class | 61 | 27 | 37 | 12 | 15 (55%) | 227 | 1 |
| `D` | narrow protocol | 14 | 6 | 7 | 6 | 0 (0%) | 230 | 0 |
| `E` | model type | 46 | 15 | 46 | 15 | 0 (0%) | 228 | 1 |

_Symbol names redacted; counts and types are real. "Files saved" = files
Claude would read with the grep approach minus files xcindex returned. Even
when file counts are equal (`D`, `E`), xcindex eliminates the per-file
scan-and-filter step by returning exact line/column/role — Claude reads
±10 lines, not the whole file._

## Why

Claude's default approach to "where is `UserService` used?" is to run `ripgrep`,
get back 40 noisy textual matches (including comments, strings, and
similarly-named symbols in unrelated modules), and then read 8 full files to
figure out what's real. That's expensive in tokens and imprecise in results.

Xcode already solved this. Every time you build in Xcode, SourceKit writes a
full semantic index of your project to disk under
`~/Library/Developer/Xcode/DerivedData/<Project>/Index.noindex/DataStore/`.
That index knows the difference between a class, a variable, and a string
literal. It understands Swift-specific semantics that textual tools can't —
protocol witnesses, extensions, `@objc` bridging, overrides, conformances.

Apple ships [`indexstore-db`](https://github.com/swiftlang/indexstore-db), the
same Swift library SourceKit-LSP uses to query that index. This plugin wraps
those queries behind MCP tools and teaches Claude (via skills, a hook, and a
subagent) when to reach for the index instead of grep.

The result: **replace shotgun reads with surgical reads**. Instead of "grep
for the name, then read 8 files," Claude asks for the reference sites of a
specific USR (unique symbol identifier), gets 6 exact file+line locations
back, and reads only the lines that matter.

## How

```
Claude Code
    ↓ (MCP over stdio)
claude-xcindex plugin
├── Skills          — tell Claude WHEN to use the index
├── Hooks           — freshness warnings at session start and after edits
├── Subagent        — isolated context for large renames
├── Slash commands  — /xcindex-setup, /xcindex-status
└── Swift binary    — MCP server, queries IndexStoreDB
    ↓ (reads LMDB)
DerivedData/Index.noindex/DataStore
    ↑ (writes during build)
Xcode
```

A single native Swift binary speaks MCP directly using Anthropic's
official [Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
and queries `IndexStoreDB` — the same library SourceKit-LSP uses. No
Node runtime, no intermediate process: Claude Code spawns the binary,
the binary talks to the index.

### MCP tool surface

Exposed under the `mcp__xcindex__*` namespace. All tools are semantic — they
match symbols, not text.

| Tool | Purpose |
|---|---|
| `find_symbol` | Given a name, return candidate USRs with kind (class/func/protocol) and defining file. Disambiguation step. |
| `find_references` | Given a symbol name, return every occurrence with file, line, column, and role (call/read/write/override). |
| `find_definition` | Given a symbol name, return the canonical definition site. |
| `find_overrides` | Given a method, return all overriding implementations. |
| `find_conformances` | Given a protocol, return all types that conform. |
| `blast_radius` | Given a file path, return the minimal set of files affected by editing it (direct dependents + covering tests). |
| `status` | Return index freshness, DerivedData path, last-build timestamp, and whether any source files have mtime newer than the index. |

### Skills

Skills are how token reduction actually happens — an MCP tool that's never
called is worthless. Each skill's `description` frontmatter is what Claude
scans to decide whether to load it.

- **`swift-find-references`** — triggers on "where is X used?", "what calls
  X?", or before a rename/signature change. Steers Claude away from grep.
- **`swift-blast-radius`** — triggers on "what does this file affect?" or
  before editing a shared utility. Steers Claude away from reading 20 files to
  "understand the codebase."
- **`swift-rename-symbol`** — triggers on explicit rename requests. Delegates
  to the `swift-refactor-specialist` subagent so the main context doesn't fill
  up with 50 file reads.

### Hooks

The index lies when the user hasn't built recently. Two hooks handle this
non-invasively.

- **SessionStart** — scans the project for an Xcode index, reports freshness,
  and warns Claude if source files are newer than the index.
- **PostToolUse** (on `Edit|Write|MultiEdit`) — records which Swift/ObjC files
  were edited this session so MCP tool responses can annotate stale results.

Builds are **never** triggered automatically. Hooks warn, they don't act.

## Requirements

- macOS 14 (Sonoma) or later — `indexstore-db` requires macOS 14+.
- macOS 13 or later.
- Xcode 16 or later, with command-line tools installed (`xcode-select --install`).
- [Claude Code](https://claude.com/claude-code).
- An Xcode project (`.xcodeproj` or `.xcworkspace`) that has been built at
  least once, so the DerivedData index exists.

## Install

From inside Claude Code:

```
/plugin install drewalth/claude-xcindex
```

The first time the plugin starts in a session, it downloads the matching
`xcindex` binary from the GitHub release and caches it under the plugin
directory. No `npm install`, no manual build step.

Then, in a Swift project:

```
/xcindex-setup
```

This command confirms the binary is ready, locates your Xcode project,
and — with your confirmation — runs `xcodebuild` for each scheme so the
symbol index is populated. Skip it if you build in Xcode yourself;
xcindex just reads whatever index Xcode has already written to
DerivedData.

Verify anytime with `/plugin` (should list `claude-xcindex`) and
`/xcindex-status` (reports the resolved index path and freshness).

### Install from source

For contributors, or if you want to pin to a specific commit:

```sh
git clone https://github.com/drewalth/claude-xcindex.git
cd claude-xcindex/service && swift build -c release
# Then in Claude Code:
/plugin install /absolute/path/to/claude-xcindex
```

The launcher detects the from-source build at
`service/.build/release/xcindex` and symlinks it instead of downloading.

## How to use

Once installed, you mostly don't interact with the plugin directly — the
skills trigger automatically based on what you ask Claude.

**Natural-language triggers that hit the plugin:**

- "Where is `UserService` used?"
- "What calls `fetchUser`?"
- "What depends on `NetworkClient.swift`?"
- "What will break if I change `AuthManager`?"
- "Rename `fetchUser` to `loadUser` across the codebase."
- "What tests cover `ModelData.swift`?"

**Explicit slash command:**

- `/xcindex-status` — check whether the index is current, where it lives, and
  which files (if any) have been edited since the last build.

**Example session:**

```
You: Find all callers of fetchUser.
Claude: [uses mcp__xcindex__find_symbol → mcp__xcindex__find_references]
        → 6 call sites across 4 files. Reads ±10 lines around each.
        Returns a focused summary instead of 8 full-file reads.
```

For renames that touch many files, Claude will delegate to the
`swift-refactor-specialist` subagent automatically — it runs in its own
context window and reports back a short summary, so your main conversation
doesn't balloon.

## Complementary tools

This plugin focuses on **semantic queries** over Xcode's on-disk index. It
is not a language server, does not operate on live source, and does not
build, test, or run your project. Pair it with:

### Anthropic's [`swift-lsp`](https://claude.com/plugins/swift-lsp)

Live language-server features — completion, diagnostics, hover,
jump-to-definition — backed by SourceKit-LSP. Different layer of the stack:
`swift-lsp` talks to a running SourceKit-LSP server over live source;
`claude-xcindex` reads the on-disk `indexstore-db` that Xcode writes during
build. They don't overlap.

| | `swift-lsp` | `claude-xcindex` |
|---|---|---|
| Backend | SourceKit-LSP server | `indexstore-db` reader |
| Source of truth | live Swift source | Xcode build-time index |
| Requires Xcode build? | No | Yes (once) |
| Diagnostics & completion | Yes | No |
| Hover / jump-to-definition | Yes | Definition only |
| Overrides / conformances / blast-radius | Not first-class | Yes |
| Works on Linux / SwiftPM-only | Yes | No (DerivedData-specific) |
| Warm query latency | LSP round-trip | sub-millisecond |
| Freshness model | always live | hook-warned when stale |

Use `swift-lsp` for IDE features on live source. Use `claude-xcindex` for
refactor-grade queries (USR-authoritative references, overrides,
conformances, blast-radius) at sub-millisecond warm latency, with explicit
freshness annotations when Claude has edited files since the last build.

### Build and test orchestration

- **Apple's [`mcpbridge`](https://developer.apple.com/documentation/xcode)**
  (ships with Xcode 26.3+) for build, test, preview, and documentation.
- **[`XcodeBuildMCP`](https://github.com/cameroncooke/XcodeBuildMCP)** for
  build/test/simulator orchestration on older Xcode versions.

Install alongside `claude-xcindex` — they don't overlap.

## Troubleshooting

**"No Xcode index found for `<project>`."**
Build the project in Xcode (Cmd+B) at least once. The plugin reads the index
Xcode writes during build.

**"N Swift file(s) newer than the index."**
Expected if you've been editing. Build in Xcode to refresh, or expect
references in those files to be slightly out of date. The plugin will
annotate stale results in its responses.

**MCP tools don't appear in Claude Code.**
Run `/plugin` to confirm the plugin is installed. If listed but tools are
missing, the launcher couldn't resolve the xcindex binary — check that
either `bin/xcindex` exists, `service/.build/release/xcindex` exists, or
a matching release asset exists at
`https://github.com/drewalth/claude-xcindex/releases`. `/xcindex-setup`
will rebuild from source as a fallback.

**Custom DerivedData location.**
The plugin reads `IDECustomDerivedDataLocation` from Xcode's preferences
automatically. If it can't find your index, run `/xcindex-status` and it
will report where it looked.

## Development

```sh
./build.sh --debug                       # debug build
cd service && swift test                 # run tests
```

Layout:

```
claude-xcindex/
├── .claude-plugin/plugin.json     # Claude Code plugin manifest
├── .mcp.json                      # MCP server registration → bin/run
├── bin/run                        # launcher: download/symlink, then exec xcindex
├── service/                       # Swift MCP server (IndexStoreDB + swift-sdk)
├── skills/                        # swift-find-references, blast-radius, rename
├── agents/swift-refactor-specialist.md
├── commands/                      # /xcindex-setup, /xcindex-status
├── hooks/                         # session-start.sh, post-edit.sh
└── build.sh                       # convenience wrapper for swift build -c release
```

Pull requests welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.
Please open an issue to discuss architectural changes before submitting.

## Prior art

- [`apple/indexstore-db`](https://github.com/swiftlang/indexstore-db) — the
  query library this plugin wraps.
- [`block/xcode-index-mcp`](https://github.com/block/xcode-index-mcp) —
  closest prior art, Python + Swift MCP server for Goose/Cursor.
- [`michaelversus/SwiftFindRefs`](https://github.com/michaelversus/SwiftFindRefs)
  — CLI with the same core query, narrower scope.

## License

MIT — see [LICENSE](./LICENSE).
