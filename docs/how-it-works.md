# How it works

This page explains the mental model behind `xcindex`: what the
index is, how freshness works, and why the tools prefer USRs over
symbol names.

## The index is not the plugin

Every time you build a project in Xcode, SourceKit (Apple's compiler
infrastructure) writes a full semantic index of your project to disk
under:

```
~/Library/Developer/Xcode/DerivedData/<Project>-<hash>/Index.noindex/DataStore/
```

That index already knows the difference between a class, a variable, and
a string literal. It understands Swift-specific semantics that textual
tools can't — protocol witnesses, extensions, `@objc` bridging,
overrides, conformances.

`xcindex` does not build anything and does not maintain its own
index. It **reads** Xcode's index using Apple's official
[`indexstore-db`](https://github.com/swiftlang/indexstore-db) library —
the same library SourceKit-LSP uses.

The upside: queries are sub-millisecond after the first one in a session
and match exactly what Xcode knows. The downside: if you haven't built
the project recently, the index is stale.

## Freshness

The index only refreshes when you build in Xcode. If Claude is editing
Swift files, the index immediately falls behind those files. The plugin
handles this with two hooks and one rule:

**Hooks.**
- A `SessionStart` hook scans the project at session start and prints a
  note if source files are newer than the index.
- A `PostToolUse` hook on `Edit|Write|MultiEdit` records the paths of
  edited Swift/ObjC files to a session state file in `$TMPDIR`.

**Rule.** Every MCP tool response calls `Freshness.staleNote(involvedPaths:)`
and appends a warning when returned paths overlap the session-edited set.
So if `find_references` returns 10 results and 3 of them are in files
Claude edited this session, Claude sees:

> Note: AppDelegate.swift, UserService.swift were edited this session
> after the index was built; results may be stale.

**Hooks warn, never act.** The plugin does not trigger builds on your
behalf. Auto-rebuilds fight the user — you decide when to rebuild.

The session state file's path is derived identically in three places
that *must* stay in sync byte-for-byte (see `CLAUDE.md` for the full
contract): the Swift code, `hooks/session-start.sh`, and
`hooks/post-edit.sh`. The `FreshnessTests` suite protects that contract.

## DerivedData resolution

Finding the right `Index.noindex/DataStore` from a project path takes
three tries:

1. If the caller passed `indexStorePath` explicitly, use it.
2. Otherwise, check Xcode's `IDECustomDerivedDataLocation` preference.
   If set, use that as the scan base.
3. Otherwise, scan `~/Library/Developer/Xcode/DerivedData/` for a
   folder whose name starts with `<ProjectName>-` and pick the most
   recently modified match.

This mirrors Xcode's own lookup behavior. The scan fallback is what
lets users who don't pin DerivedData paths "just work."

## USR-first lookups

A USR (Unified Symbol Resolution identifier) is a string that uniquely
identifies a symbol across the whole index. Think of it like an email
address for a Swift symbol: `s:9CanaryApp11UserServiceC9fetchUser2idSSSgSS_tF`
is the USR of `UserService.fetchUser(id:)`.

Most tools in this plugin take a USR:

```
find_symbol("UserService")
    ↓ returns candidate USRs + kinds
find_references(usr: "s:...")
find_definition(usr: "s:...")
find_overrides(usr: "s:...")
find_conformances(usr: "s:...")
```

Skills train Claude to do this two-step: `find_symbol` first for
disambiguation (if more than one `UserService` exists), then the
USR-based tool. This matters because name-based lookups can be
ambiguous — two unrelated modules might both define `User`. USR-based
lookups can't.

## Why `grep` loses

The pitch in the README shows numbers ("up to 70% fewer files to
read"). The mechanism behind those numbers:

- **`grep` returns textual matches.** "User" matches `UserService`,
  `CurrentUser`, `userID`, `"user"` in a string literal, `// user`
  in a comment, and `User` in a completely unrelated module. You
  then have to read each file to figure out which hits are real.
- **`xcindex` returns symbol occurrences.** Each result is a
  `(file, line, column, role, USR)` tuple, where `role` tells you
  whether this is a definition, call, read, write, or override.
  Claude reads ±10 lines around each occurrence, not the whole file.

The plugin's hot path is sub-millisecond because `indexstore-db` keeps
the index memory-mapped after the first read. The first query in a
session pays a ~1–5 s warm-up to open the store; every subsequent query
is essentially free.

## What the index does NOT have

- **Live edits** — SourceKit writes the index during build. Edits you
  haven't built yet are invisible. (That's why the freshness hooks
  exist.)
- **SwiftPM packages you haven't built from their own root** — if your
  project is a workspace that references a package, make sure you've
  built *the workspace scheme* so the package's sources get indexed
  into the same DataStore.
- **Platforms you haven't built for** — if your project builds for iOS
  but you ran `swift build` from the command line (which targets
  macOS), the symbols for iOS-only code paths won't be in the index.
- **Generated code that `xcodebuild` doesn't see** — tools like SwiftGen
  and Sourcery must run before the build so their output is on disk
  when SourceKit indexes.

## Further reading

- [`apple/indexstore-db`](https://github.com/swiftlang/indexstore-db) —
  the query library this plugin wraps.
- Apple's blog post on
  [the Swift symbol graph](https://www.swift.org/documentation/articles/symbol-graph.html)
  — the conceptual foundation for how SourceKit models symbols.
- [Tools reference](tools-reference.md) — what each MCP tool does,
  signature, and example responses.
