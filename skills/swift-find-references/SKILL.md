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
- "What imports this?" / "What depends on Y?"
- Before editing a public API to estimate impact
- Before renaming a symbol (use `/swift-rename-symbol` for the full rename workflow)
- Before reading through files to trace a call chain

# When NOT to use

- The symbol is local to one file (just read the file directly)
- The user is asking about a string literal or comment (use Grep)
- `xcindex_status` reports the index is stale and the user hasn't built recently
- The project has no DerivedData (never built in Xcode)

# How to use

1. **Disambiguate first** — call `xcindex_find_symbol` with the name to get candidate USRs.
   - If multiple results, pick the one matching the correct module/kind.
   - If exactly one result, proceed directly.

2. **Find references** — call `xcindex_find_references` with the `symbolName`.
   - Use `maxResults: 100` (default) for most symbols.
   - For framework entry points or common types, use `maxResults: 200–500`.

3. **Read surgically** — read only the files that appear in the results, and
   only the lines near the reported occurrences — **not the full files**.
   A typical reference site needs ±10 lines of context.

# Token-saving pattern

```
BAD:  rg "UserService" --include="*.swift"   → 40 noisy text matches, 8 full file reads
GOOD: xcindex_find_references("UserService") → 6 exact locations, 6 focused reads
```

The index gives semantic matches: it distinguishes `UserService` the class from
`userService` the variable, and from "UserService" in a comment string. Grep
cannot do this.

# Example workflow

User: "What calls `fetchUser`?"

1. `xcindex_find_symbol(symbolName: "fetchUser")` → USR `s:9MyApp0A4ServiceC9fetchUseryySiF`
2. `xcindex_find_references(symbolName: "fetchUser")` → 4 call sites
3. Read the 4 locations with ±10 lines each → done
