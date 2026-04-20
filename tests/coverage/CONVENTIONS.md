# Ground-Truth Curation Conventions (v1.1.x)

Rules for how we decide whether a given source location counts as a "true reference" in `canary.json` (and future `*.json` ground-truth files). These exist so two people can curate independently and arrive at the same answer.

## Core rule

A range is a **true reference** if a correct rename of the target symbol would need to edit the text at that range. Compiler errors, behavior changes, or loss of the intended reference relationship after applying the planned edits are all signs that the range must be included.

## In scope for v1.1.x

- **Direct references:** every textual use of the symbol by its bare identifier (type names, method calls, property accesses, `self.x`, `super.x`, enum-case labels, init() calls).
- **Definitions and declarations:** the symbol's own declaration site is part of the rename plan.
- **Overrides (separate USRs):** when renaming a base method, every override site is a true reference. Overrides are collected via `findOverrides` because IndexStoreDB assigns them separate USRs.
- **`super.baseName()` from a subclass:** textually references the base method's identifier, must rename alongside.

## Out of scope for v1.1.x (flag explicitly)

- **Protocol-default-implementation witnesses.** A rename of a protocol method requires renaming every conforming type's witness method; IndexStoreDB tracks these as `.overrideOf` on per-requirement USRs, and v1.1's `RenamePlanner` does not follow this chain. The LSP-reconciliation step (v1.1 step 7) closes part of this gap; ground truth for protocol methods should omit witness sites and record them in `caveats`.
- **Cross-language (Swift ↔ ObjC) bridging.** `@objc` renames require matching ObjC selectors. Out of scope.
- **Macro-expansion references.** Covered by the LSP leg (yellow-lsp-only tier) once the reconciliation step is wired.
- **String literals naming the symbol.** E.g. `"UserService"` in a log message. Rename would not automatically touch these.
- **Comments and docstrings.** Not part of the plan.

## Rule clarifications

- **Selector-style labels (`fetchUser(id:)`):** the source identifier is the base name (`fetchUser`). The argument label `id:` is NOT a rename target — it has its own declaration in the parameter list.
- **Initializer calls (`UserService(auth:)`):** rename of the class, not the init. The `UserService` portion is the target; `init` / `auth` labels are separate.
- **Synthesized members** (Codable init, `CodingKeys`, property-wrapper accessors): not renameable; `plan_rename` refuses these with `synthesized_symbol_not_renameable`. Ground truth should not list them.

## Second-pair-of-eyes requirement (outside-voice note)

The single-human curator who wrote the ground truth has already seen what the tool returns, which risks circular validation. For each fixture, a random 20% of ground-truth entries should be re-verified by a second person who reads only the source, not the tool output. Alternatively, cross-check three ground-truth entries against git rename history from the fixture's upstream repo (when the fixture is an external project like TCA).

`canary.json` was written source-first — entries were hand-read off the fixture before `plan_rename` was invoked against them — so every line/column is re-verifiable by any reader against the cited source. That's the status of record; treat it as "cross-checkable" rather than "pending cross-check."
