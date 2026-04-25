---
name: swift-refactor-plan
description: Produce a complete written refactor plan for Swift or Objective-C code — rename, signature change, type extraction, protocol split, API migration — listing every site that will change (grouped by file with line numbers), the risks (overrides, conformances, @objc bridging, cross-module public API, test coverage), and the recommended execution path. Pure planning — makes zero edits. Use whenever the user wants to scope, preview, or estimate a Swift change before committing to it.
when_to_use: |
  Trigger on planning-flavored phrasing like "plan a rename of X", "what would
  changing X involve", "before I rename, show me what changes", "I'm thinking
  about extracting Y", "preview the rename of Z", "scope this refactor", "what
  is the impact of changing AuthService's signature", "draft a migration plan
  from old API to new", "is this rename safe", "how big a change is this". Also
  reach for this skill whenever the user is in plan-mode-style discussion about
  Swift code, even without the word "plan" — any request to understand a change
  before making it qualifies. Use BEFORE swift-rename-symbol when the user wants
  to inspect the surface first. Skip and go straight to swift-rename-symbol /
  swift-find-references when the user has clearly committed ("just do it", "go
  ahead and rename", "apply it now").
---

# What this skill does

Builds a written plan for a Swift refactor. It does **not** edit code. The plan
is what you hand to the user (or to swift-rename-symbol) so the actual edits can
happen with full context.

A good plan answers four questions:

1. **What's the target?** A specific symbol, or a file as a unit.
2. **What sites will change?** Every reference, grouped by file and line.
3. **What can go wrong?** Overrides, conformances, `@objc` bridging, public API
   crossing module boundaries, missing test coverage.
4. **How should it be executed?** A specific recommended path —
   `swift-rename-symbol`, manual edits in N files, or "this needs more design
   work first."

The xcindex MCP tools provide the raw data; this skill orchestrates the queries
and turns the result into a plan.

# How to use

## Step 1 — Decide the target shape

The user's phrasing tells you whether the unit is a **symbol** or a **file**.

- "Rename `fetchUser` to `loadUser`" → symbol.
- "What if I split `NetworkClient.swift` into two files" → file.
- "Migrate from `OldAuthAPI` to `NewAuthAPI`" → multiple symbols (treat each
  separately, then aggregate).

If the user named only a file but the change is really about a symbol inside it
(e.g. "what if I change the signature of the function in `Auth.swift`"),
disambiguate before querying.

## Step 2 — Gather data

Run only the queries that match the target shape. Skip anything irrelevant.

**Symbol target:**

1. `find_symbol(symbolName: <name>)` → resolve to a USR. If multiple results,
   pick the one matching the user's stated module/kind, or ask.
2. `find_definition(symbolName: <name>)` → confirm the definition site.
3. `find_references(symbolName: <name>, maxResults: 200)` → every reference.
4. If the symbol is a method or property: `find_overrides(symbolName: <name>)` —
   subclass overrides break silently if missed.
5. If the symbol is a protocol or protocol requirement:
   `find_conformances(symbolName: <name>)` — every conformer must update.

**File target:**

1. `blast_radius(filePath: <abs path>)` → `directDependents`, `affectedFiles`,
   `coveringTests`.
2. Optionally narrow per-symbol with `find_references` for the specific symbols
   inside the file the user is changing.

## Step 3 — Surface risks

Walk the results and flag each of these that applies:

| Risk | Signal |
| --- | --- |
| **Overrides** | `find_overrides` returns ≥1 site — subclasses must change in lockstep. |
| **Protocol conformances** | `find_conformances` returns ≥1 site — every conformer must update. |
| **`@objc` bridging** | `find_references` returns sites with `.dynamic` role — Objective-C call sites outside the index may exist. |
| **Cross-module public API** | Reference sites span multiple modules — downstream packages may break. |
| **No covering tests** | `blast_radius.coveringTests` is empty for the affected files — regression risk; recommend adding one before the change. |
| **Stale index** | MCP returned a freshness warning — note that the plan may be incomplete until the user rebuilds. |

A risk-free plan is fine — write "No notable risks" rather than inventing
filler.

## Step 4 — Write the plan

Use this exact structure so plans are skimmable and the user can act on them
directly:

```markdown
## Refactor plan: <one-line description>

**Target:** <symbol or file, with USR if applicable>
**Type:** <rename | signature change | extraction | migration | other>
**Total impact:** <N files, M reference sites>

### Sites by file

- `path/to/A.swift` (<count>)
  - L<line> — <role: call | override | conformance | definition | test>
  - L<line> — ...
- `path/to/B.swift` (<count>)
  - ...

### Covering tests

- `path/to/ATests.swift`
- ...

(or "None — recommend adding test coverage before proceeding")

### Risks

- ⚠ <risk> — <one-sentence explanation>
- ✓ <thing-that-could-have-been-a-risk-but-isn't>

### Recommended execution

<one of:>
- Use `swift-rename-symbol` — dispatches the rename via the
  swift-refactor-specialist subagent. Estimated subagent context: ~<N>k tokens.
- Manual edits in <list of files> — recommended when sites need
  case-by-case judgment (e.g. some calls need migration shims).
- Pause and decide on <X> first — recommended when the plan surfaces a design
  question the rename can't resolve (e.g. an `@objc` requirement, a behavior
  change disguised as a rename).
```

## Step 5 — Hand off

End your message by telling the user what's available next:

- "Want me to dispatch this to swift-rename-symbol?" (if the recommendation is
  the automated path)
- "Want me to start with `<file>` so you can review the first edit?" (if manual)
- "Want me to look at <X> before we decide?" (if paused)

Don't start editing on your own — this skill's job ends with the plan.

# Example

**User:** "I'm thinking about renaming `fetchUser` to `loadUser`. What would
that touch?"

**You:**

1. `find_symbol("fetchUser")` → one USR, in `MyApp.UserService`.
2. `find_references("fetchUser", maxResults: 200)` → 11 sites across 6 files.
3. `find_overrides("fetchUser")` → 0 (it's a free function on the class).
4. Review the role of each site (calls vs definition).

```markdown
## Refactor plan: rename `UserService.fetchUser` → `loadUser`

**Target:** `s:9MyApp...fetchUserSiF` (UserService.fetchUser)
**Type:** rename
**Total impact:** 6 files, 11 sites

### Sites by file

- `Sources/UserService.swift` (2)
  - L42 — definition
  - L67 — internal call
- `Sources/AuthFlow.swift` (3)
  - L18, L24, L91 — calls
- `Sources/ProfileViewModel.swift` (2)
  - L33, L120 — calls
- `Tests/UserServiceTests.swift` (3)
  - L12, L45, L88 — calls
- `Tests/AuthFlowTests.swift` (1)
  - L23 — call

### Covering tests

- `Tests/UserServiceTests.swift`
- `Tests/AuthFlowTests.swift`

### Risks

- ✓ No subclass overrides.
- ✓ No protocol conformance — it's a concrete method.
- ✓ Not `@objc` — no Objective-C bridging surface.
- ✓ Tests cover both the direct method and one downstream caller.

### Recommended execution

Use `swift-rename-symbol` — straightforward rename, all sites are direct calls,
test coverage is solid. Estimated subagent context: ~2k tokens.
```

"Want me to dispatch this to `swift-rename-symbol`?"

# When this skill won't help

- The user has already committed and just wants action — go to
  `swift-rename-symbol` directly.
- The change is a pure behavior change inside a single function with no API
  surface — there's nothing to plan; just edit.
- The user is asking a textual question ("how many places say `TODO`?") — that's
  Grep, not the index.

# Related skills

- **swift-rename-symbol** — the execution path this plan often recommends.
- **swift-find-references** — the underlying query for symbol-level sites; use
  it directly when the user only wants the reference list.
- **swift-blast-radius** — the underlying query for file-level impact; use it
  directly when the user only wants the affected-files set.
