<!--
Thanks for contributing to claude-xcindex!

- Keep PRs focused. One logical change per PR is easier to review and revert.
- Follow Conventional Commits for the PR title (e.g. `feat:`, `fix:`,
  `docs:`, `refactor:`, `test:`, `chore:`, `build:`, `ci:`). The title
  becomes the release-note line via semantic-release.
- Breaking changes: use `feat!:` or include `BREAKING CHANGE:` in the
  body so semantic-release bumps the major version.
-->

## Summary

<!-- What does this change and why? 1-3 sentences. -->

## Linked issues / discussions

<!-- "Closes #123" or "Refs #123" if applicable. -->

## How was this tested?

<!--
- `cd service && swift test`
- Manual: describe the Claude Code session you ran this through.
- New or updated tests if behavior changed.
-->

## Checklist

- [ ] Conventional Commits-compatible PR title.
- [ ] Tests added/updated if behavior changed.
- [ ] `./build.sh` passes locally.
- [ ] `cd service && swift test` passes locally.
- [ ] `CHANGELOG.md`'s `[Unreleased]` section updated if user-visible.
- [ ] Docs updated (`README.md`, `CLAUDE.md`, or `docs/`) if applicable.
- [ ] No new telemetry, analytics, or remote pings added (this plugin is local-only by design).
