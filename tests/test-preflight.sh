#!/usr/bin/env bash
# Regression tests for the preflight guard in bin/run.
#
# Each case stubs `uname` and/or `xcodebuild` in a temp directory prepended to
# $PATH so the real bin/run preflight function sees controlled output without
# touching the network or the real binary.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_RUN="${SCRIPT_DIR}/../bin/run"

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

# run_preflight <stub_dir> [plugin_root]
# Invokes bin/run with the stub directory prepended to PATH (so real system
# tools like awk, head, dirname, etc. remain available). Captures stderr into
# $stderr_out and the exit status into $status.
run_preflight() {
    local stub_dir="$1"
    local plugin_root="${2:-}"
    local env_args=()
    [[ -n "$plugin_root" ]] && env_args=(env CLAUDE_PLUGIN_ROOT="$plugin_root")

    stderr_out=$(PATH="${stub_dir}:${PATH}" \
        "${env_args[@]}" \
        bash "$BIN_RUN" </dev/null 2>&1 >/dev/null || true)
    status=${PIPESTATUS[0]:-$?}
    # Rerun to capture actual exit code (command substitution above hides it).
    PATH="${stub_dir}:${PATH}" \
        "${env_args[@]}" \
        bash "$BIN_RUN" </dev/null >/dev/null 2>/dev/null
    status=$?
}

# Variant that captures exit code correctly alongside stderr.
run_preflight_capture() {
    local stub_dir="$1"
    local plugin_root="${2:-}"
    local env_prefix=()
    [[ -n "$plugin_root" ]] && env_prefix=(CLAUDE_PLUGIN_ROOT="$plugin_root")

    stderr_out=$(PATH="${stub_dir}:${PATH}" \
        env "${env_prefix[@]}" \
        bash "$BIN_RUN" </dev/null 2>&1 >/dev/null) || true
    PATH="${stub_dir}:${PATH}" \
        env "${env_prefix[@]}" \
        bash "$BIN_RUN" </dev/null >/dev/null 2>/dev/null
    status=$?
}

# ── helper: make a stub dir with given executables ───────────────────────────

make_stub() {
    local dir="$1"; shift
    mkdir -p "$dir"
    while [[ $# -ge 2 ]]; do
        local name="$1" body="$2"; shift 2
        printf '#!/usr/bin/env bash\n%s\n' "$body" > "${dir}/${name}"
        chmod +x "${dir}/${name}"
    done
}

# ── Case 1: Non-macOS → must fail with macOS mention ─────────────────────────

s1="${root}/case1/stubs"
make_stub "$s1" \
    uname 'echo "Linux"'

stderr_out=""
status=0
{ stderr_out=$(PATH="${s1}:${PATH}" bash "$BIN_RUN" </dev/null 2>&1 >/dev/null); } 2>/dev/null || true
PATH="${s1}:${PATH}" bash "$BIN_RUN" </dev/null >/dev/null 2>/dev/null; status=$?

if [[ $status -ne 0 ]] && echo "$stderr_out" | grep -qi "macos"; then
    pass "Non-macOS: exits non-zero and mentions macOS"
else
    fail "Non-macOS: expected non-zero exit + macOS in stderr (status=$status, stderr='$stderr_out')"
fi

# ── Case 2: Old Xcode (15.x) → must fail mentioning Xcode/16 ────────────────

s2="${root}/case2/stubs"
make_stub "$s2" \
    uname 'echo "Darwin"' \
    xcodebuild 'printf "Xcode 15.4\nBuild version 15F31d\n"'

stderr_out=""
status=0
{ stderr_out=$(PATH="${s2}:${PATH}" bash "$BIN_RUN" </dev/null 2>&1 >/dev/null); } 2>/dev/null || true
PATH="${s2}:${PATH}" bash "$BIN_RUN" </dev/null >/dev/null 2>/dev/null; status=$?

if [[ $status -ne 0 ]] && (echo "$stderr_out" | grep -qi "xcode" || echo "$stderr_out" | grep -q "16"); then
    pass "Old Xcode (15.x): exits non-zero and mentions Xcode or 16"
else
    fail "Old Xcode (15.x): expected non-zero exit + Xcode/16 in stderr (status=$status, stderr='$stderr_out')"
fi

# ── Case 3: Missing xcodebuild → must fail mentioning Xcode ──────────────────
#
# xcodebuild lives at /usr/bin/xcodebuild on macOS, so we must not include
# /usr/bin in the PATH for this case. To keep awk and head available (which
# bin/run also calls), symlink them from their real locations into the stub dir.

s3="${root}/case3/stubs"
make_stub "$s3" \
    uname 'echo "Darwin"'
# Bring awk and head into the stub dir without /usr/bin (which has xcodebuild).
ln -sf "$(command -v awk)"  "${s3}/awk"
ln -sf "$(command -v head)" "${s3}/head"

stderr_out=""
status=0
{ stderr_out=$(PATH="${s3}:/bin" bash "$BIN_RUN" </dev/null 2>&1 >/dev/null); } 2>/dev/null || true
PATH="${s3}:/bin" bash "$BIN_RUN" </dev/null >/dev/null 2>/dev/null; status=$?

if [[ $status -ne 0 ]] && echo "$stderr_out" | grep -qi "xcode"; then
    pass "Missing xcodebuild: exits non-zero and mentions Xcode"
else
    fail "Missing xcodebuild: expected non-zero exit + Xcode in stderr (status=$status, stderr='$stderr_out')"
fi

# ── Case 4: Happy path (Darwin, Xcode 16+, stub binary) → exits 0 ────────────

s4="${root}/case4/stubs"
make_stub "$s4" \
    uname 'echo "Darwin"' \
    xcodebuild 'printf "Xcode 16.0\nBuild version 16A242d\n"'

# Build a fake plugin root so ensure_binary finds a stub xcindex binary.
plugin4="${root}/case4/plugin"
mkdir -p "${plugin4}/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "${plugin4}/bin/xcindex"
chmod +x "${plugin4}/bin/xcindex"

stderr_out=""
status=0
{ stderr_out=$(PATH="${s4}:${PATH}" CLAUDE_PLUGIN_ROOT="${plugin4}" bash "$BIN_RUN" </dev/null 2>&1 >/dev/null); } 2>/dev/null || true
PATH="${s4}:${PATH}" CLAUDE_PLUGIN_ROOT="${plugin4}" bash "$BIN_RUN" </dev/null >/dev/null 2>/dev/null; status=$?

if [[ $status -eq 0 ]]; then
    pass "Happy path (Darwin, Xcode 16, stub binary): exits 0"
else
    fail "Happy path: expected exit 0 (status=$status, stderr='$stderr_out')"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'All %d preflight checks passed.\n' "$PASS"
    exit 0
else
    printf '%d/%d preflight check(s) failed.\n' "$FAIL" "$((PASS + FAIL))" >&2
    exit 1
fi
