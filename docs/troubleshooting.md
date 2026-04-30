# Troubleshooting

If something's not working, **run the diagnostic first**:

```sh
./bin/xcindex-doctor
```

It checks Xcode, `libIndexStore.dylib`, `swiftc`, the cached binary, your
project's DerivedData, and index freshness — each line prints `OK` or
`FAIL` with a remediation hint. You can also pass `--project /path/to/Foo.xcodeproj`
to point at a specific project instead of auto-detecting from the current
directory.

If the doctor is green but Claude still isn't using the tools, check
`/plugin` and `/xcindex-status` in a Claude Code session to confirm the
MCP server is registered.

---

## "No Xcode index found for `<project>`."

Xcode writes the symbol index during builds. If you haven't built the
project in Xcode, there's nothing for `xcindex` to read.

**Fix:** open the project in Xcode and build it (Cmd+B). Or, if you
prefer command-line, run `/xcindex-setup` in Claude Code and it will
build each scheme with `xcodebuild` after confirming with you.

Once a build completes, `~/Library/Developer/Xcode/DerivedData/<Project>-*/Index.noindex/DataStore`
will exist and `xcindex` can read it.

## "N Swift file(s) newer than the index."

Expected if you've been editing. The plugin's `SessionStart` and
`PostToolUse` hooks detect this automatically and annotate MCP tool
responses with `results may be stale` for edited files.

**Fix:** build in Xcode to refresh. Or ignore — stale annotations tell
Claude which specific results to treat cautiously, and the rest of the
index is still authoritative.

## Tools don't appear in Claude Code

1. Run `/plugin` — `xcindex` should be listed. If it isn't,
   install it: `/plugin install drewalth/claude-xcindex`.
2. If it's listed but the `mcp__xcindex__*` tools are missing, the
   launcher couldn't resolve the Swift binary. Check:
   - `bin/xcindex` exists and is executable, **or**
   - `service/.build/release/xcindex` exists (from-source build), **or**
   - A matching asset exists at
     <https://github.com/drewalth/claude-xcindex/releases>.
3. As a fallback, run `/xcindex-setup` — it will rebuild from source if
   the binary is missing.

## Custom DerivedData location

Xcode stores a custom path in `IDECustomDerivedDataLocation`. The plugin
reads this preference automatically, so no configuration is needed.

If it's still not found, run `/xcindex-status` and it will report the
exact path it looked in.

## `find_symbol` returns results but `find_references` returns `[]`

IndexStoreDB stores Swift method names with their argument labels baked
in — `fetchUser(id:)` rather than `fetchUser`. An exact-name query with
the bare name will miss.

**Fix:** pass the full signature (`fetchUser(id:)`). Claude's skills
usually handle this automatically when you phrase a request
naturally ("where is `fetchUser` called?").

## `find_conformances` shows no results for a Swift protocol

This was a bug prior to the post-v1.0 fix — Swift protocol conformance
isn't recorded as a direct class→protocol relation in the index; it's
stored as per-method `.overrideOf` relations on the witness functions.
The current build traverses that correctly.

If you're on an older version, `/plugin update` and retry.

## Install from source on a fresh machine

```sh
git clone https://github.com/drewalth/claude-xcindex.git
cd claude-xcindex
./build.sh                       # ~30s on an M-series Mac
./bin/xcindex-doctor             # confirm environment is ready
# Then in Claude Code:
/plugin install /absolute/path/to/claude-xcindex
```

## Still stuck

Open an [issue](https://github.com/drewalth/claude-xcindex/issues/new/choose)
or a [discussion](https://github.com/drewalth/claude-xcindex/discussions).
The bug-report template asks for the fields that diagnose most
problems — please include the full `xcindex-doctor` output.
