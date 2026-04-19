# Tools reference

Every tool lives under the `mcp__xcindex__*` MCP namespace. You won't
usually call them by name — the plugin's skills trigger them from
natural-language questions — but this page documents the surface for
anyone building automations, writing their own skills, or debugging.

All tools accept the same `projectPath` / `indexStorePath` pair for
locating the index; the section below covers those once and the
per-tool sections don't repeat them.

## Locating the index

Every tool needs to find the `Index.noindex/DataStore` directory
somehow. Three ways to tell it which:

- `projectPath: string` — absolute path to a `.xcodeproj` or
  `.xcworkspace`. The plugin derives the DerivedData location
  automatically (see [how-it-works.md](how-it-works.md#deriveddata-resolution)).
- `indexStorePath: string` — absolute path to the DataStore directory.
  Overrides `projectPath`. Useful in CI or when you've built with
  `swift build` and want to point at `.build/<triple>/debug/index/store`.
- *Neither* — the plugin errors with a clear message. It does not guess.

Use `status` first if you don't know the path.

---

## `find_symbol`

Look up candidate symbols by name. Use this **first** when multiple
symbols might share the name (overloads, types in different modules,
methods with the same base name on different types).

**Input**
- `symbolName: string` (required) — exact, case-sensitive name. For
  Swift methods with argument labels, use the full form:
  `fetchUser(id:)`, not `fetchUser`.

**Output** — array of:
```json
{
  "usr": "s:9MyApp11UserServiceC",
  "name": "UserService",
  "kind": "class",
  "language": "swift",
  "definitionPath": "/Users/me/MyApp/Sources/UserService.swift",
  "definitionLine": 3
}
```

The `usr` is the input for every other tool in this list.

---

## `find_references`

Find every occurrence of a symbol: definitions, declarations,
references, calls, reads, writes, and overrides.

**Input**
- `symbolName: string` (required) — same shape as `find_symbol`.
- `maxResults: int` (default 100, max 500) — cap on returned
  occurrences. For very common symbols, raise only if you genuinely
  need the full picture.

**Output** — array of:
```json
{
  "usr": "s:9MyApp11UserServiceC9fetchUser2idSSSgSS_tF",
  "symbolName": "fetchUser(id:)",
  "path": "/Users/me/MyApp/Sources/AppDelegate.swift",
  "line": 9,
  "column": 22,
  "roles": ["reference", "call"]
}
```

Results are deduplicated by `(path, line, column)` and sorted by
`path`, then `line`, then `column`.

---

## `find_definition`

Given a USR, return the single canonical definition site. Falls back
to a declaration if no non-system definition exists.

**Input**
- `usr: string` (required) — from `find_symbol` or `find_references`.

**Output** — one occurrence (same shape as `find_references` entries)
or `null` if not found.

---

## `find_overrides`

Given a method's USR, find all overriding implementations in
subclasses. Essential before changing a method signature.

**Input**
- `usr: string` (required) — USR of the base method.

**Output** — array of occurrences (same shape as `find_references`).

---

## `find_conformances`

Given a Swift protocol's USR, find all types that conform to it.

**Input**
- `usr: string` (required) — USR of the protocol.

**Output** — array of occurrences, each at the conforming type's
definition site.

**Note.** Swift's index does not record a direct class→protocol
relation — conformance is stored as per-method `.overrideOf` relations
on each witness. The tool traverses that correctly, but it means
conformances added via an extension will appear anchored at the
extended type's *original* definition, not the extension.

---

## `blast_radius`

Given a source file, return the minimal set of other files that
depend on it:

- **Direct dependents.** Files that import or call symbols defined
  in the target.
- **Transitive callers.** One hop — files that call into direct
  dependents.
- **Covering tests.** The subset of affected files whose names
  contain `Test` or `Spec`.

Use before editing a shared utility to know which tests to run and
which files to re-read.

**Input**
- `filePath: string` (required) — absolute path to the Swift/ObjC
  source file.

**Output**
```json
{
  "affectedFiles": ["/.../AppDelegate.swift", "/.../CanaryTests.swift"],
  "directDependents": ["/.../AppDelegate.swift", "/.../CanaryTests.swift"],
  "coveringTests": ["/.../CanaryTests.swift"]
}
```

Note that `affectedFiles` ⊇ `directDependents` and
`coveringTests` ⊆ `affectedFiles`.

---

## `status`

Report index freshness. Use as a first call at session start, or
when you suspect the index is stale.

**Input** — only the location fields (`projectPath` or
`indexStorePath`).

**Output**
```json
{
  "indexStorePath": "/Users/.../DerivedData/MyApp-.../Index.noindex/DataStore",
  "indexMtime": "2026-04-19T09:22:31Z",
  "staleFileCount": 0,
  "staleFiles": [],
  "summary": "Index store found at … (last modified 2026-04-19T09:22:31Z)."
}
```

The per-session stale-file tracking lives in the `SessionStart` and
`PostToolUse` hooks, not in this tool's return — `status` reports
index health, the hooks report live edits.

---

## Error handling

Every tool returns a plain text error in the MCP response when
something goes wrong. Common cases:

- `No DerivedData folder for '<Project>' under …` — you haven't built
  the project in Xcode. Build it first.
- `Either 'projectPath' or 'indexStorePath' must be provided.` —
  neither argument was passed.
- `DerivedData folder '…' exists but has no Index.noindex/DataStore` —
  the project built but indexing was disabled. Enable it in Xcode:
  Settings → General → Indexing.

See [troubleshooting.md](troubleshooting.md) for the full list.
