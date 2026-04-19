# Contributing to claude-xcindex

Thanks for your interest in contributing. This document covers the
basics for getting your changes merged.

## Prerequisites

- macOS 14+ with Xcode 16+
- Swift 6.1+
- [Claude Code](https://claude.com/claude-code) for end-to-end testing
- Optional: [SwiftFormat](https://github.com/nicklockwood/SwiftFormat)
  (`brew install swiftformat`) — CI enforces it

## Getting started

```sh
git clone https://github.com/drewalth/claude-xcindex.git
cd claude-xcindex
./build.sh --debug
cd service && swift test
```

First-time setup sanity check:

```sh
./bin/xcindex-doctor
```

Reports pass/fail on Xcode, `libIndexStore.dylib`, `swiftc`, the cached
binary, DerivedData resolution, and freshness.

## Git workflow

Create a feature branch from `main`:

```sh
git checkout main
git pull origin main
git checkout -b feature/your-feature-name
```

Branch name prefixes are informational only — the commit messages are
what drive the release.

## Commits — Conventional Commits (required)

This repo uses [Conventional Commits](https://www.conventionalcommits.org/)
to drive [semantic-release](https://semantic-release.gitbook.io/).
**The PR title is what ends up in the release notes and determines the
version bump**, so get the prefix right.

| Prefix | Version bump | Use for |
|---|---|---|
| `feat:` | minor (x.Y.0) | a new user-visible capability |
| `fix:` | patch (x.y.Z) | a bug fix |
| `docs:` | none (unless you set `scope: release`) | docs-only changes |
| `refactor:` | none | behavior-preserving cleanup |
| `test:` | none | adding or adjusting tests |
| `chore:` / `build:` / `ci:` | none | tooling, deps, workflow |
| `feat!:` (or `BREAKING CHANGE:` in body) | major (X.0.0) | incompatible change |

Example body:

```
feat: add maxDepth parameter to blast_radius

- Exposes an optional cap on traversal depth (default 10)
- Prevents runaway queries on deep dependency graphs

Closes #42
```

First line ≤72 chars, imperative mood, no trailing period. Body
explains *why*, not *how*.

## Running tests

```sh
cd service
swift test --parallel           # all tests, fresh index per run
swift test --filter FreshnessTests
swift test --filter 'IndexQuerier/findRefs'
```

Tests run against a throwaway SwiftPM canary fixture under
`service/Tests/Fixtures/CanaryApp`. Nothing in your home directory or
DerivedData is touched.

Coverage philosophy: **happy path + freshness edge cases**, not 100%.
One passing test per MCP tool is the confidence bar; deep exhaustive
coverage on the freshness/DerivedData contracts that are load-bearing
for correctness.

## How to add a new MCP tool

Every tool is plumbed through four places — keep them in sync. See
`CLAUDE.md` for the architectural context; this is the mechanical
checklist.

1. **Register the tool schema.**
   `service/Sources/xcindex/MCPServer.swift` — add a new `Tool` constant
   inside `ToolDefinitions`, then append it to `ToolDefinitions.all`.
   This is where the user-visible name, description, and input schema
   live.

2. **Dispatch.**
   Same file, in `Dispatcher.handle`. Add a `case` for your new
   tool name that extracts arguments and calls a new
   `handle<YourOp>` method on the processor.

3. **Processor op.**
   `service/Sources/xcindex/RequestProcessor.swift` — add a
   `handle<YourOp>` async method. Resolve the index store via
   `DerivedDataLocator` (reuse, don't reimplement), load the cached
   `IndexQuerier` via the actor, call the query, and return a typed
   result.

4. **Query method.**
   `service/Sources/xcindex/Queries.swift` — add the `IndexStoreDB`
   call and data shaping on `IndexQuerier`. Structured data out, not
   user-facing strings — formatting happens in `MCPServer.swift`.

5. **Test it.**
   `service/Tests/xcindexTests/IndexQuerierTests.swift` — one
   happy-path test against the canary fixture. If the tool needs
   symbols the fixture doesn't have yet, add them to
   `service/Tests/Fixtures/CanaryApp/Sources/CanaryApp/*.swift` and
   document the additions in comments.

6. **Document it.**
   Add an entry to `docs/tools-reference.md` and, if user-relevant,
   mention it in the README's tool surface table.

Optional but usually expected:

- A skill under `skills/<tool-name>/SKILL.md` to train Claude on when
  to reach for the tool.
- CHANGELOG `[Unreleased]` entry.

## Pull requests

Before submitting:

1. **Build passes**: `./build.sh`
2. **Tests pass**: `cd service && swift test`
3. **Format passes**: `swiftformat --lint .` (or `swiftformat .` to auto-fix)
4. **CHANGELOG updated** if the change is user-visible
5. **Manual test in Claude Code** for anything that affects MCP tool
   behavior

Open the PR against `main`. The template (`/.github/pull_request_template.md`)
has a checklist. Address review feedback with new commits — don't
force-push during review. PRs squash-merge on land.

## Code style

- Follow existing patterns. Four-space indent, MARK comments for
  section dividers.
- No force-unwrapping unless the crash is intentional. Explain why in
  a comment at the unwrap site.
- Prefer clarity over cleverness.
- Document public APIs; inline comments only for *why*, not *what*.
- Run `swiftformat .` before pushing.

## Labels (maintainers)

Issue and PR labels are managed via
[`scripts/setup-labels.sh`](scripts/setup-labels.sh). Run it once to
bootstrap (or re-apply) the area labels (`freshness`, `index`,
`mcp-protocol`, `plugin`) on top of GitHub's defaults:

```sh
./scripts/setup-labels.sh
```

Idempotent — safe to re-run when adding a new area.

## Releasing (maintainers)

Releases are automated on every push to `main`:

1. semantic-release analyzes the merged commits since the last tag.
2. If any `feat:` / `fix:` / `feat!:` commits exist, it bumps the
   version in the generated GitHub release notes and writes a
   `.release-version` file.
3. The next CI job builds a universal binary
   (`arm64 + x86_64`), codesigns it ad-hoc, and uploads it to the
   release.
4. The `bin/run` launcher's `/releases/latest/download/` URL
   resolves to the new asset automatically — no plugin.json
   version bump is needed for users to pick up the new binary.

To preview what the next release will contain:

```sh
git log --oneline $(git describe --tags --abbrev=0)..HEAD
```

To land a change *without* triggering a release, use `docs:`,
`chore:`, `refactor:`, `test:`, `build:`, or `ci:` prefixes.

## Questions?

- Bugs and feature requests: [open an issue](https://github.com/drewalth/claude-xcindex/issues/new/choose).
- Security vulnerabilities: see [SECURITY.md](./SECURITY.md).
- Usage questions and early-stage ideas: [Discussions](https://github.com/drewalth/claude-xcindex/discussions).
