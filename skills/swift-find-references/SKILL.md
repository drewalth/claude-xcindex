---
name: swift-find-references
description: Find every semantic reference to a Swift or Objective-C symbol via Xcode's pre-built index — no false positives from comments, string literals, or similarly-named symbols in unrelated modules. Use this when planning a change to scope its surface, before grep/ripgrep, and before reading files to trace call chains.
when_to_use: |
  Trigger on phrasing like "where is X called", "what uses X", "find all references
  to X", "callers of fetchUser", "who calls this", "what depends on Y", "trace the
  callers of Z", "estimate the impact of changing the signature of X". Reach for
  this skill BEFORE running rg/grep on .swift files, BEFORE reading multiple files
  to trace a call chain, and BEFORE editing any public API. For broader scoping
  (sites + risks + recommended execution path) use swift-refactor-plan instead.
  Skip only when the symbol is obviously local to a single file or the user is
  searching string literals/comments (use Grep for those).
---

# What this skill does

Maps a symbol name to its semantic reference set using the Xcode IndexStoreDB.
The index distinguishes a `UserService` class from a `userService` variable, from
a `UserService` token in a comment, and from `UserService` defined in another
module. Grep cannot.

# How to use

1. **Disambiguate first.** Call `find_symbol` with the name to get candidate USRs.
   - Multiple results: pick the one matching the right module/kind, or ask the
     user which they meant.
   - One result: proceed.

2. **Find references.** Call `find_references` with the `symbolName`.
   - `maxResults: 100` is the default and covers most symbols.
   - Framework entry points or common types: bump to `200–500`.

3. **Read surgically.** Open only the files in the result, and only ±10 lines
   around each reported occurrence. Do not read whole files — the index already
   told you the lines that matter.

# Token-saving pattern

```
BAD:  rg "UserService" --include="*.swift"
      → 40 noisy matches, 8 full file reads, unrelated comment hits
GOOD: find_references("UserService")
      → 6 exact locations, 6 focused ±10-line reads
```

# Example

User: "What calls `fetchUser`?"

1. `find_symbol(symbolName: "fetchUser")` → USR `s:9MyApp...fetchUseryySiF`
2. `find_references(symbolName: "fetchUser")` → 4 call sites
3. Read those 4 windows. Done.

# When it won't help

- Local symbol used only in its defining file — just read the file.
- The user is asking about a string literal, log message, or comment — that's a
  text search, not a symbol search.
- The index is stale and the user hasn't built recently — `find_references` will
  silently miss new sites. The MCP server appends a freshness warning when it
  detects stale results; honor it.
- The project has never been built in Xcode (no DerivedData) — there is no index
  yet.

# Related skills

- **swift-refactor-plan** — when the user wants a full plan (sites + risks +
  recommended next step), not just the reference list.
- **swift-blast-radius** — when the unit of analysis is a *file*, not a symbol.
- **swift-rename-symbol** — when the user has committed to renaming and wants the
  edits applied.
