#!/usr/bin/env bash
# Regression tests for hooks/pre-grep.sh
#
# pre-grep.sh nudges Claude toward the semantic xcindex tools when it is about
# to Grep Swift/ObjC source, and stays out of the way for everything else. The
# behavior this guards:
#   1. It fires only on an explicit Swift/ObjC signal — a glob ending in
#      .swift/.m/.mm, type=swift, or a path ending in one of those — and emits
#      the PreToolUse JSON contract (hookEventName + additionalContext).
#   2. Free-text greps (TODO comments, log lines, literals) and non-Swift globs
#      produce NO output, so ordinary searches are unaffected.
#   3. Tool input is accepted via both the CLAUDE_TOOL_INPUT env var and stdin.
#   4. Malformed/empty input is a silent no-op, and the hook always exits 0 so
#      the Grep is never blocked.
#   5. The .h asymmetry with post-edit.sh: .h is NOT a pre-grep signal (only
#      .swift/.m/.mm are), so a header-file grep is not nudged.
#
# Self-contained and deterministic: no filesystem or env state is read beyond
# what each case passes in.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../../hooks/pre-grep.sh"

PASS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }

# run_env <tool_input_json>: deliver input via the CLAUDE_TOOL_INPUT env var.
run_env() {
    output=$(CLAUDE_TOOL_INPUT="$1" bash "$HOOK" 2>&1)
    status=$?
}

# run_stdin <tool_input_json>: deliver input via stdin with the env var unset,
# exercising the newer stdin convention path.
run_stdin() {
    output=$(printf '%s' "$1" | env -u CLAUDE_TOOL_INPUT bash "$HOOK" 2>&1)
    status=$?
}

# Assert the PreToolUse nudge was emitted.
assert_nudged() {
    local label="$1"
    [[ "$status" -eq 0 ]] || fail "$label: expected exit 0, got $status (output: '$output')"
    case "$output" in
        *'"hookEventName": "PreToolUse"'*) ;;
        *) fail "$label: expected PreToolUse JSON, got: '$output'" ;;
    esac
    case "$output" in
        *'additionalContext'*) ;;
        *) fail "$label: expected additionalContext in nudge, got: '$output'" ;;
    esac
    ok "$label"
}

# Assert the hook stayed silent (exit 0, no output).
assert_silent() {
    local label="$1"
    [[ "$status" -eq 0 ]] || fail "$label: expected exit 0, got $status (output: '$output')"
    [[ -z "$output" ]] || fail "$label: expected no output, got: '$output'"
    ok "$label"
}

# ── Swift/ObjC signals → nudge ───────────────────────────────────────────────
run_env '{"pattern":"foo","glob":"*.swift"}'
assert_nudged 'glob *.swift triggers the nudge'

run_env '{"pattern":"foo","type":"swift"}'
assert_nudged 'type=swift triggers the nudge'

run_env '{"pattern":"foo","path":"Sources/App/View.swift"}'
assert_nudged 'a path ending in .swift triggers the nudge'

run_env '{"pattern":"foo","glob":"*.m"}'
assert_nudged 'glob *.m (ObjC) triggers the nudge'

run_env '{"pattern":"foo","glob":"*.mm"}'
assert_nudged 'glob *.mm (ObjC++) triggers the nudge'

# ── No Swift signal → silent ─────────────────────────────────────────────────
run_env '{"pattern":"TODO"}'
assert_silent 'free-text grep (pattern only) stays silent'

run_env '{"pattern":"foo","glob":"*.ts"}'
assert_silent 'a non-Swift glob stays silent'

# ── .h asymmetry: post-edit tracks .h, pre-grep does NOT nudge on it ─────────
run_env '{"pattern":"foo","glob":"*.h"}'
assert_silent 'a *.h glob is NOT a pre-grep signal (matches the documented set)'

# ── Delivery channels ────────────────────────────────────────────────────────
run_stdin '{"pattern":"foo","glob":"*.swift"}'
assert_nudged 'input delivered via stdin is honored'

# ── Malformed / empty input → silent no-op, never blocks ─────────────────────
run_env '{not valid json'
assert_silent 'malformed JSON is a silent no-op'

run_stdin ''
assert_silent 'empty stdin input is a silent no-op'

printf '\nAll %d pre-grep hook checks passed.\n' "$PASS"
