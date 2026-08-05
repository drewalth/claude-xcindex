#!/usr/bin/env bash
# Regression tests for scripts/set-plugin-version.sh
#
# semantic-release calls this script in its `prepare` step, and
# @semantic-release/git then commits the result to main. That makes the script
# the only thing keeping .claude-plugin/plugin.json -- the plugin's install
# cache key -- in lockstep with the tag being cut. The contracts guarded here:
#   1. The version field is rewritten to exactly the argument given.
#   2. Every other field, and the key order, survives untouched. The manifest is
#      hand-authored; a rewrite that reordered it would turn every release into
#      a whole-file diff and bury real edits.
#   3. Output stays 2-space indented with a trailing newline, so the release
#      commit is a one-line diff.
#   4. A malformed or missing version is rejected before anything is written.
#      A bad value here is baked into the manifest and only surfaces later, at
#      install time, far from its cause.
#
# Self-contained: each case builds a sandbox holding a copy of the script and a
# fixture manifest, so no assertion touches the real repo manifest. The script
# resolves its target relative to its own location, which is exactly what the
# sandbox reproduces.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../../scripts/set-plugin-version.sh"

PASS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

[[ -x "$SCRIPT" ]] || fail "set-plugin-version.sh is missing or not executable"

# Build a sandbox repo: <box>/scripts/set-plugin-version.sh reachable from
# <box>/.claude-plugin/plugin.json, mirroring the real layout.
new_box() {
    local box
    box=$(mktemp -d "${root}/box.XXXXXX")
    mkdir -p "${box}/scripts" "${box}/.claude-plugin"
    cp "$SCRIPT" "${box}/scripts/set-plugin-version.sh"
    cat >"${box}/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "xcindex",
  "version": "1.2.3",
  "description": "Query Xcode's pre-built symbol index from Claude Code.",
  "license": "MIT",
  "keywords": [
    "swift",
    "xcode"
  ]
}
JSON
    printf '%s' "$box"
}

version_of() {
    node -e 'process.stdout.write(require(process.argv[1]).version)' \
        "${1}/.claude-plugin/plugin.json"
}

# ── 1. Rewrites the version ──────────────────────────────────────────────────
box=$(new_box)
"${box}/scripts/set-plugin-version.sh" 3.0.3 >/dev/null 2>&1 \
    || fail "rejected a valid version"
[[ "$(version_of "$box")" == "3.0.3" ]] \
    || fail "version not rewritten (got '$(version_of "$box")')"
ok "rewrites the version field"

# ── 2. Leaves every other field, and the key order, alone ────────────────────
keys=$(node -e 'process.stdout.write(Object.keys(require(process.argv[1])).join(","))' \
    "${box}/.claude-plugin/plugin.json")
[[ "$keys" == "name,version,description,license,keywords" ]] \
    || fail "key order changed: ${keys}"
desc=$(node -e 'process.stdout.write(require(process.argv[1]).description)' \
    "${box}/.claude-plugin/plugin.json")
[[ "$desc" == "Query Xcode's pre-built symbol index from Claude Code." ]] \
    || fail "an unrelated field was altered"
ok "preserves key order and unrelated fields"

# ── 3. Formatting stays diff-clean ───────────────────────────────────────────
grep -q '^  "name": "xcindex",$' "${box}/.claude-plugin/plugin.json" \
    || fail "indentation is no longer 2 spaces"
[[ -z "$(tail -c 1 "${box}/.claude-plugin/plugin.json")" ]] \
    || fail "trailing newline was dropped"
ok "keeps 2-space indent and a trailing newline"

# ── 4. Rejects bad input without writing ─────────────────────────────────────
for bad in "v3.0.3" "3.0" "" "not-a-version" "3.0.3; rm -rf /"; do
    box=$(new_box)
    "${box}/scripts/set-plugin-version.sh" "$bad" >/dev/null 2>&1
    rc=$?
    [[ $rc -eq 2 ]] || fail "accepted invalid version '${bad}' (exit ${rc})"
    [[ "$(version_of "$box")" == "1.2.3" ]] \
        || fail "manifest was modified despite rejecting '${bad}'"
done
ok "rejects malformed and empty versions, leaving the manifest untouched"

# ── 5. Missing manifest is an error, not a silent no-op ──────────────────────
box=$(new_box)
rm "${box}/.claude-plugin/plugin.json"
"${box}/scripts/set-plugin-version.sh" 3.0.3 >/dev/null 2>&1
[[ $? -eq 1 ]] || fail "missing manifest did not exit 1"
ok "fails loudly when the manifest is absent"

printf '\n%d/%d passed\n' "$PASS" "$PASS"
