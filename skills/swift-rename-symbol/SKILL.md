---
name: swift-rename-symbol
description: Use when the user explicitly asks to rename a Swift symbol, method,
  property, type, or protocol across the codebase. Uses the Xcode index for
  semantic precision — renames only the actual symbol, not same-named text in
  comments or unrelated modules. Delegates to swift-refactor-specialist subagent
  to avoid filling the main context with 50 file reads.
---

# When to use

- "Rename X to Y" / "Change `fetchUser` to `loadUser`" / "Rename the `AuthDelegate` protocol"
- Before a rename, to get a full picture of the change surface

# When NOT to use

- The rename is local to one file (just use Edit directly)
- The user wants to *find* references without renaming (use `swift-find-references`)
- The index is stale — rebuild in Xcode first for an accurate rename

# How to use

**Delegate to the `swift-refactor-specialist` subagent.** Do not do the rename
in the main session — you'll fill your context with 50 file reads.

The subagent has `xcindex_*` tools, `Read`, and `Edit`. It will:
1. Find all reference sites
2. Edit each site atomically
3. Return a short summary: N files changed, list of edit sites

In the main session:
1. Announce: "I'll use the swift-refactor-specialist to rename this across the codebase."
2. Dispatch to the subagent with: old name, new name, project/index path
3. Review the summary and verify a few key sites

# Rename workflow (what the subagent does)

1. `xcindex_find_symbol(symbolName: "OldName")` → USR + definition location
2. Confirm USR is correct (right kind, right module)
3. `xcindex_find_references(symbolName: "OldName")` → all occurrence sites
4. For each site: `Edit` to replace `OldName` with `NewName` at the exact line
5. Handle the definition site last (may be a different replacement e.g. class name vs func body)
6. Return summary

# Edge cases

- **Overloads**: `xcindex_find_symbol` returns multiple USRs → ask which one to rename
- **@objc bridging**: `xcindex_find_references` with `.dynamic` role flags dynamic dispatch sites
- **Extensions in other files**: the index includes extension references; check `containedBy` roles
- **Test doubles / mocks**: check `coveringTests` via blast radius to ensure mocks are updated

# Token budget

A typical rename touching 8 files uses ~2000 tokens in the subagent context,
vs ~15000 tokens if done in the main session with full file reads.
