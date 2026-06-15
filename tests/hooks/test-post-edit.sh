#!/usr/bin/env bash
# Regression tests for hooks/post-edit.sh
#
# post-edit.sh records each Swift/ObjC file Claude edits into the session state
# file so the MCP server can flag that file's symbols as possibly-stale. The
# load-bearing contracts this guards:
#   1. The state-file path is derived identically to
#      service/Sources/xcindex/Freshness.swift#stateFilePath:
#      "$TMPDIR/xcindex-edited-<sha1(cwd) first 12 chars>.txt", and
#      CLAUDE_PROJECT_DIR overrides cwd. If this drifts, the hook and the Swift
#      reader stop sharing a file and stale-tracking silently breaks.
#   2. Only Swift/ObjC sources (.swift/.m/.mm/.h) are tracked; everything else
#      is ignored with no output.
#   3. Paths are absolutized and de-duplicated, and both the `file_path` and
#      `path` JSON keys are honored.
#   4. The "Exit 0 always" + trap contract: a write failure warns instead of
#      vanishing, and an abnormal abort still forces exit 0 with a diagnostic.
#
# Self-contained and deterministic: TMPDIR and CLAUDE_PROJECT_DIR are pinned
# into a sandbox per-case so no assertion touches the developer's real $TMPDIR
# or leaves state behind.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../../hooks/post-edit.sh"

PASS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }

root=$(mktemp -d)
# chmod -R u+w first: a read-only-$TMPDIR case below strips write perms, and the
# empty dir must be made removable again before rm can clean up.
trap 'chmod -R u+w "$root" 2>/dev/null; rm -rf "$root"' EXIT

# Independent re-derivation of the Freshness.swift#stateFilePath spec. The hook
# must land its state file exactly here; if either side changes the algorithm,
# this assertion catches the divergence.
state_file_for() {
    local cwd="$1" tmp="$2" hash
    tmp="${tmp%/}"
    hash=$(printf '%s' "$cwd" | shasum -a 1 | cut -c1-12)
    printf '%s/xcindex-edited-%s.txt' "$tmp" "$hash"
}

# run_hook <tool_input_json> [project_dir] [tmpdir] [cwd] [path]
# Captures stdout+stderr into $output and the exit code into $status. cwd is the
# directory bash runs from (only relevant for relative-path absolutization);
# CLAUDE_PROJECT_DIR drives the state-file hash independently of cwd.
run_hook() {
    local input="$1" proj="${2:-$root/proj}" tmp="${3:-$root/tmp}" cwd="${4:-${2:-$root/proj}}" path="${5:-$PATH}"
    mkdir -p "$proj" "$tmp" "$cwd"
    output=$(cd "$cwd" && CLAUDE_TOOL_INPUT="$input" CLAUDE_PROJECT_DIR="$proj" TMPDIR="$tmp" PATH="$path" bash "$HOOK" 2>&1)
    status=$?
}

# ── Case 1: a Swift edit is recorded at the contract path ────────────────────
p1="$root/case1/proj"; t1="$root/case1/tmp"
run_hook "{\"file_path\":\"$p1/Foo.swift\"}" "$p1" "$t1"
[[ "$status" -eq 0 ]] || fail "case1: expected exit 0, got $status (output: '$output')"
sf1=$(state_file_for "$p1" "$t1")
[[ -f "$sf1" ]] || fail "case1: state file not created at contract path '$sf1'"
grep -qxF "$p1/Foo.swift" "$sf1" || fail "case1: edited path not recorded in '$sf1'"
case "$output" in
    *"'Foo.swift' was edited"*) ;;
    *) fail "case1: expected stale-warning for Foo.swift, got: '$output'" ;;
esac
ok 'Swift edit recorded at the Freshness.swift contract path + warns'

# ── Case 2: CLAUDE_PROJECT_DIR drives the hash, not cwd ───────────────────────
# Run from an unrelated cwd; the state file must still be keyed on the project
# dir, matching how the Swift side resolves it.
p2="$root/case2/proj"; t2="$root/case2/tmp"; cwd2="$root/case2/elsewhere"
run_hook "{\"file_path\":\"$p2/Bar.swift\"}" "$p2" "$t2" "$cwd2"
[[ "$status" -eq 0 ]] || fail "case2: expected exit 0, got $status"
sf2=$(state_file_for "$p2" "$t2")
[[ -f "$sf2" ]] || fail "case2: state file should be keyed on CLAUDE_PROJECT_DIR, not cwd (expected '$sf2')"
ok 'state-file hash keyed on CLAUDE_PROJECT_DIR independent of cwd'

# ── Case 3: non-Swift files are ignored, no output, no state file ────────────
p3="$root/case3/proj"; t3="$root/case3/tmp"
run_hook "{\"file_path\":\"$p3/README.md\"}" "$p3" "$t3"
[[ "$status" -eq 0 ]] || fail "case3: expected exit 0, got $status"
[[ -z "$output" ]] || fail "case3: non-Swift edit should produce no output, got: '$output'"
[[ ! -f "$(state_file_for "$p3" "$t3")" ]] || fail "case3: non-Swift edit must not create a state file"
ok 'non-Swift file ignored — no output, no state file'

# ── Case 4: ObjC sources (.m/.mm/.h) are tracked too ─────────────────────────
for ext in m mm h; do
    p="$root/case4-$ext/proj"; t="$root/case4-$ext/tmp"
    run_hook "{\"file_path\":\"$p/Obj.$ext\"}" "$p" "$t"
    [[ "$status" -eq 0 ]] || fail "case4: .$ext expected exit 0, got $status"
    grep -qxF "$p/Obj.$ext" "$(state_file_for "$p" "$t")" \
        || fail "case4: .$ext source should be tracked but was not recorded"
done
ok 'ObjC sources (.m/.mm/.h) are tracked'

# ── Case 5: the `path` key is honored as a fallback for `file_path` ──────────
p5="$root/case5/proj"; t5="$root/case5/tmp"
run_hook "{\"path\":\"$p5/Alt.swift\"}" "$p5" "$t5"
[[ "$status" -eq 0 ]] || fail "case5: expected exit 0, got $status"
grep -qxF "$p5/Alt.swift" "$(state_file_for "$p5" "$t5")" \
    || fail "case5: the 'path' JSON key should be honored when 'file_path' is absent"
ok "the 'path' key is honored when 'file_path' is absent"

# ── Case 6: relative paths are absolutized before recording ──────────────────
# Run from the project dir and pass a bare filename; the recorded entry must be
# the absolute path (the index reports absolute paths, so the compare must too).
p6="$root/case6/proj"; t6="$root/case6/tmp"
mkdir -p "$p6"; : > "$p6/Rel.swift"
run_hook '{"file_path":"Rel.swift"}' "$p6" "$t6" "$p6"
[[ "$status" -eq 0 ]] || fail "case6: expected exit 0, got $status"
grep -qxF "$p6/Rel.swift" "$(state_file_for "$p6" "$t6")" \
    || fail "case6: relative path should be absolutized to '$p6/Rel.swift'"
ok 'relative path absolutized before recording'

# ── Case 7: a file edited twice is recorded once ─────────────────────────────
p7="$root/case7/proj"; t7="$root/case7/tmp"
run_hook "{\"file_path\":\"$p7/Dup.swift\"}" "$p7" "$t7"
run_hook "{\"file_path\":\"$p7/Dup.swift\"}" "$p7" "$t7"
[[ "$status" -eq 0 ]] || fail "case7: expected exit 0, got $status"
count=$(grep -cxF "$p7/Dup.swift" "$(state_file_for "$p7" "$t7")")
[[ "$count" -eq 1 ]] || fail "case7: duplicate edit should be recorded once, found $count entries"
ok 'duplicate edit of the same file recorded once'

# ── Case 8: empty tool input is a no-op ──────────────────────────────────────
p8="$root/case8/proj"; t8="$root/case8/tmp"
run_hook "" "$p8" "$t8"
[[ "$status" -eq 0 ]] || fail "case8: expected exit 0, got $status"
[[ -z "$output" ]] || fail "case8: empty input should produce no output, got: '$output'"
[[ ! -f "$(state_file_for "$p8" "$t8")" ]] || fail "case8: empty input must not create a state file"
ok 'empty tool input is a silent no-op'

# ── Case 9: an unwritable state file warns instead of vanishing ──────────────
# A read-only $TMPDIR makes the append fail. The trap would otherwise mask this
# as success; the hook must detect the failed write and warn explicitly.
p9="$root/case9/proj"; t9="$root/case9/tmp"
mkdir -p "$t9"; chmod 555 "$t9"
run_hook "{\"file_path\":\"$p9/Locked.swift\"}" "$p9" "$t9"
chmod 755 "$t9"
[[ "$status" -eq 0 ]] || fail "case9: expected exit 0 even on write failure, got $status"
case "$output" in
    *"could not record edit to 'Locked.swift'"*) ;;
    *) fail "case9: unwritable state file should warn, got: '$output'" ;;
esac
ok 'unwritable state file warns instead of silently dropping the edit'

# ── Case 10: trap backstop forces exit 0 + diagnostic on abnormal abort ──────
# Shim `shasum` to fail; under set -e/pipefail the state-file hash aborts the
# script mid-stream. The trap must still force exit 0 AND emit its diagnostic.
BROKEN="$root/broken"; mkdir -p "$BROKEN"
cat > "$BROKEN/shasum" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
chmod +x "$BROKEN/shasum"
p10="$root/case10/proj"; t10="$root/case10/tmp"
run_hook "{\"file_path\":\"$p10/Boom.swift\"}" "$p10" "$t10" "$p10" "$BROKEN:$PATH"
[[ "$status" -eq 0 ]] || fail "case10: trap must force exit 0 on abnormal abort, got $status (output: '$output')"
case "$output" in
    *"post-edit hook exited unexpectedly"*) ;;
    *) fail "case10: expected trap diagnostic on abort, got: '$output'" ;;
esac
ok 'trap backstop forces exit 0 and emits a diagnostic on abnormal abort'

printf '\nAll %d post-edit hook checks passed.\n' "$PASS"
