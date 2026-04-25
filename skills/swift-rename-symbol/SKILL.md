---
name: swift-rename-symbol
description: Execute a semantic rename of a Swift or Objective-C symbol — type, method, property, protocol, enum case — across the codebase via Xcode's index, dispatched to the swift-refactor-specialist subagent so the main context isn't flooded with 50 file reads. Renames the actual symbol; never touches similarly-named text in comments or unrelated modules.
when_to_use: |
  Trigger on phrasing like "rename X to Y", "change fetchUser to loadUser",
  "rename the AuthDelegate protocol", "go ahead and rename", "do the rename now",
  "apply the rename across the project". Use this skill only once the user has
  committed to the rename. If they're still scoping ("what would this rename
  touch", "preview the rename", "is it safe to rename X") use swift-refactor-plan
  first — it produces the plan, this skill executes it. Skip when the rename is
  local to a single file (just use Edit directly) or when the index is stale and
  the user hasn't rebuilt in Xcode (rebuild first or the rename will miss sites).
---

# What this skill does

Performs an index-backed rename: every reference site for the symbol's USR is
edited, and only those sites. Same-named tokens in comments, string literals, or
unrelated modules are left alone.

The work is delegated to the **swift-refactor-specialist** subagent. The main
session doesn't read 50 files — it gets a short summary back.

# How to use

1. Confirm with the user that this is an execution step, not a scoping step.
   If you're not sure, run `swift-refactor-plan` first and ask.
2. Announce: "I'll dispatch the rename to the swift-refactor-specialist."
3. Hand the subagent: old name, new name, project path (or index store path).
4. Review the returned summary; spot-check 2–3 representative sites if the
   rename touched many files.

# What the subagent does

The subagent has `find_symbol`, `find_references`, `find_definition`,
`find_overrides`, `blast_radius`, `Read`, and `Edit`. It will:

1. `find_symbol(symbolName: "OldName")` → resolve to a USR + definition site.
2. Confirm the USR is the right kind/module. If multiple match, return to the
   main session and ask.
3. `find_references(symbolName: "OldName")` → every occurrence.
4. `Edit` each site precisely. The definition site is handled last and may need
   a different replacement (e.g. class header vs. body usage).
5. Return: number of files touched, list of edited paths, anything skipped.

# Edge cases the subagent flags

- **Overloads** — multiple USRs for the same name. Surface the choice; don't
  guess.
- **`@objc` bridging** — `find_references` flags `.dynamic` roles. Objective-C
  call sites *outside* the index are invisible; warn the user.
- **Extensions in other files** — included by the index; check `containedBy`
  roles in the result so extension headers update with the type.
- **Protocol conformances and overrides** — use `find_overrides` and
  `find_conformances` to avoid leaving a dangling subclass.
- **Test doubles / mocks** — `coveringTests` from `blast_radius` should also
  update; the subagent reports any mock site it edits.

# Token budget

A rename touching ~8 files: ~2,000 tokens in the subagent context vs ~15,000 if
done inline in the main session. The subagent isolation is the point.

# Related skills

- **swift-refactor-plan** — produce a written plan first; recommended whenever
  the rename is non-trivial or the user hasn't seen the surface.
- **swift-find-references** — if you only want references, not edits.
- **swift-blast-radius** — for file-level (not symbol-level) impact.
