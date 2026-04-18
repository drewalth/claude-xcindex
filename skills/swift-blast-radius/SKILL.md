---
name: swift-blast-radius
description: Use BEFORE reading multiple files when the user asks "what does this
  file affect?", "what depends on X?", or "what will break if I change Y?". Also
  use before editing a shared utility or service to understand the minimal set of
  files you need to read. Returns direct dependents, transitive callers, and
  covering test files — replaces reading the whole project.
---

# When to use

- "What uses `AuthService.swift`?" / "What will break if I change this file?"
- "What tests cover this code?"
- Before making a structural change to a shared type or utility
- When the user asks for the blast radius, impact, or dependents of a file
- Before starting a refactor to scope the work

# When NOT to use

- You want references to a specific *symbol* (use `swift-find-references` instead)
- The file is a leaf (views, specific ViewModels) with obviously no callers
- The index is stale — blast radius will be incomplete

# How to use

1. Call `xcindex_blast_radius` with the absolute file path.
2. Read the result:
   - `directDependents` — files that directly call symbols defined in the target file
   - `affectedFiles` — direct + one hop of transitive callers
   - `coveringTests` — test files in the affected set
3. Read only the files in `directDependents` (and `coveringTests` if you need tests).
   Skip `affectedFiles` unless you're doing a deep refactor.

# Token-saving pattern

```
BAD:  Read 20 files to "understand the codebase" before editing NetworkClient.swift
GOOD: xcindex_blast_radius("NetworkClient.swift")
      → directDependents: [APIService.swift, AuthManager.swift]
      → coveringTests: [NetworkClientTests.swift]
      Read only those 3 files. Save 17 file reads.
```

# Example workflow

User: "I need to refactor `ModelData.swift`. What do I need to read first?"

1. `xcindex_blast_radius(filePath: "/path/to/ModelData.swift")`
2. Returns 5 direct dependents + 2 test files
3. Read those 7 files → understand the full impact surface
4. Make the refactor with confidence
