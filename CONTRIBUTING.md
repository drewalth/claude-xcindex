# Contributing to claude-xcindex

Thanks for your interest in contributing. This document covers the basics for getting your changes merged.

## Prerequisites

- macOS 14+ with Xcode 16+
- Swift 6.0+
- [Claude Code](https://claude.com/claude-code) for end-to-end testing

## Getting Started

```sh
git clone https://github.com/drewalth/claude-xcindex.git
cd claude-xcindex
./build.sh --debug
cd service && swift test
```

## Git Workflow

### Branching

Create a feature branch from `main`:

```sh
git checkout main
git pull origin main
git checkout -b feature/your-feature-name
```

Branch naming conventions:
- `feature/` — new functionality
- `fix/` — bug fixes
- `docs/` — documentation only
- `refactor/` — code restructuring without behavior change

### Commits

Write clear, concise commit messages:

```
Add blast_radius depth limit parameter

- Expose maxDepth option in MCP tool schema
- Default to 10 to prevent runaway traversal
- Update skill to document the new parameter
```

- First line: imperative mood, ≤72 chars
- Body: what and why, not how

## Pull Requests

### Before Submitting

1. **Build passes**: `./build.sh`
2. **Tests pass**: `cd service && swift test`
3. **Lint clean**: no compiler warnings
4. **Tested manually**: verify in Claude Code with a real Xcode project

### PR Description

Include:

- **What**: one-sentence summary of the change
- **Why**: the problem this solves or feature it adds
- **How**: brief technical approach (if non-obvious)
- **Testing**: how you verified it works

Example:

```markdown
## What
Add `maxDepth` parameter to `blast_radius` tool.

## Why
Deep dependency graphs can cause multi-second queries. Users need a way to bound traversal.

## How
Added optional `maxDepth` field to the tool schema, defaults to 10. The Swift implementation stops recursion at that depth.

## Testing
- Unit test for depth limiting in `BlastRadiusTests.swift`
- Manual test on a 300-file project: query returns in <100ms with depth=5
```

### Review Process

1. Open a PR against `main`
2. Address review feedback with new commits (don't force-push during review)
3. Squash on merge

## What to Contribute

**Good first issues:**
- Documentation improvements
- Additional test coverage
- Error message clarity

**Discuss first** (open an issue):
- New MCP tools
- Architectural changes
- New skills or hooks

## Code Style

- Follow existing patterns in the codebase
- Prefer clarity over cleverness
- No force-unwrapping unless the crash is intentional
- Document public APIs

## Questions?

Open an issue or start a discussion. We're happy to help you get your contribution merged.
