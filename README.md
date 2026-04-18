# claude-xcindex

A [Claude Code](https://claude.com/claude-code) plugin that gives Claude
surgical, semantic access to Xcode's pre-built symbol index — so refactors,
reference lookups, and impact analysis on Swift/ObjC projects cost a fraction
of the tokens of `grep`-and-read-file workflows.

---

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
├── Slash command   — /xcindex-status
├── MCP server (TS) — tool registration, schema, error handling
└── Swift service   — spawned subprocess, queries IndexStoreDB
    ↓ (reads LMDB)
DerivedData/Index.noindex/DataStore
    ↑ (writes during build)
Xcode
```

Claude Code only talks to the MCP server. The TypeScript MCP server spawns a
tiny Swift binary and communicates with it over its own stdio JSON-RPC. All
MCP schema, descriptions, freshness logic, and error handling live in
TypeScript. The Swift binary stays small — a request/response loop over
`IndexStoreDB`.

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
- Xcode with command-line tools installed (`xcode-select --install`).
- Node.js 18 or later.
- [Claude Code](https://claude.com/claude-code).
- An Xcode project (`.xcodeproj` or `.xcworkspace`) that has been built at
  least once, so the DerivedData index exists.

## Install

### 1. Clone and build

```sh
git clone https://github.com/<your-username>/claude-xcindex.git
cd claude-xcindex
./build.sh
```

The build script compiles both the TypeScript MCP server and the Swift binary.
Re-run it after `git pull`.

### 2. Install into Claude Code

From inside Claude Code, add the plugin as a local marketplace entry:

```
/plugin marketplace add /absolute/path/to/claude-xcindex
/plugin install claude-xcindex
```

Verify:

```
/plugin
```

You should see `claude-xcindex` listed, and `mcp__xcindex__*` tools should
appear in Claude's tool list.

### 3. Build your Xcode project once

The plugin reads Xcode's on-disk index. If you've never built the project in
Xcode (Cmd+B), the index won't exist. Build once; the plugin takes care of
everything from there, and will warn you if the index goes stale.

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

This plugin focuses on **semantic queries** over an already-built index. It
does not build, test, or run your project. Pair it with:

- **Apple's [`mcpbridge`](https://developer.apple.com/documentation/xcode)**
  (ships with Xcode 26.3+) for build, test, preview, and documentation.
- **[`XcodeBuildMCP`](https://github.com/cameroncooke/XcodeBuildMCP)** for
  build/test/simulator orchestration on older Xcode versions.

Install both — they don't overlap.

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
missing, check that `./build.sh` completed without errors — specifically,
that `mcp/dist/server.js` and `mcp/swift-service/.build/release/xcindex`
both exist.

**Custom DerivedData location.**
The plugin reads `IDECustomDerivedDataLocation` from Xcode's preferences
automatically. If it can't find your index, run `/xcindex-status` and it
will report where it looked.

## Development

```sh
./build.sh --debug          # debug build, both layers
cd mcp && npm run dev       # watch TypeScript
```

Layout:

```
claude-xcindex/
├── .claude-plugin/plugin.json     # Claude Code plugin manifest
├── .mcp.json                      # MCP server registration
├── mcp/
│   ├── src/                       # TypeScript MCP server
│   └── swift-service/             # Swift CLI wrapping IndexStoreDB
├── skills/                        # swift-find-references, blast-radius, rename
├── agents/swift-refactor-specialist.md
├── commands/xcindex-status.md
├── hooks/                         # session-start.sh, post-edit.sh
└── build.sh
```

Pull requests welcome. Please open an issue to discuss architectural changes
before submitting.

## Prior art

- [`apple/indexstore-db`](https://github.com/swiftlang/indexstore-db) — the
  query library this plugin wraps.
- [`block/xcode-index-mcp`](https://github.com/block/xcode-index-mcp) —
  closest prior art, Python + Swift MCP server for Goose/Cursor.
- [`michaelversus/SwiftFindRefs`](https://github.com/michaelversus/SwiftFindRefs)
  — CLI with the same core query, narrower scope.

## License

MIT — see [LICENSE](./LICENSE).
