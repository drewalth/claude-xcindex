# Security Policy

## Supported versions

Only the latest released version of `claude-xcindex` receives fixes. Check
the [releases page](https://github.com/drewalth/claude-xcindex/releases)
for the current version.

## Reporting a vulnerability

Please **do not open a public GitHub issue** for security reports.

Prefer [GitHub's private vulnerability reporting](https://github.com/drewalth/claude-xcindex/security/advisories/new)
for this repository. If that's unavailable to you, email
`andrew.althage@gmail.com` with a description and reproduction steps.

Expected response: acknowledgement within 7 days, triage within 14 days.
If the finding is confirmed, coordinated disclosure is preferred — a fix
will be released before public details are published.

## Scope

`claude-xcindex` is a local-only MCP plugin. It:

- Reads Xcode's on-disk symbol index from your `DerivedData/` directory.
- Writes a session-state file under `$TMPDIR/xcindex-edited-*.txt`
  containing paths of Swift/ObjC files edited in the current Claude Code
  session.
- Downloads a matching release binary from GitHub on first use and caches
  it under the plugin directory.
- Speaks MCP over stdio to the Claude Code CLI.

The plugin does not collect, transmit, or store any personal data or
telemetry. The only outbound network request is to `github.com` for the
binary download.

Reports of particular interest:

- Path traversal or unsanitized shell invocation in the launcher
  (`bin/run`) or hooks (`hooks/*.sh`).
- Binary download integrity — the launcher resolving to an unexpected
  asset.
- Any way the plugin could be induced to read or write files outside
  `DerivedData/`, the plugin directory, or `$TMPDIR`.
- Prompt injection via index contents that would cause the MCP server to
  return attacker-controlled output.

Out of scope:

- Bugs in `indexstore-db`, `swift-sdk`, or Xcode itself — please report
  those upstream.
- Denial-of-service from malformed local inputs that require local
  filesystem access to trigger.
