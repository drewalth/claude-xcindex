#!/usr/bin/env bash
# Regression test for hooks/session-start.sh
#
# Guards against issue #9: the hook aborted with exit 1 and no output on
# projects with a bare *.xcodeproj (no standalone *.xcworkspace), because
#   1. find matched the auto-generated MyApp.xcodeproj/project.xcworkspace,
#      so PROJECT_NAME resolved to "project" instead of "MyApp", and
#   2. the empty DerivedData glob tripped `set -e`/pipefail before the
#      "no index found" guard could print and exit 0.
#
# This test is self-contained: it points at a temp project with no real
# DerivedData index, so the expected path is the "No Xcode index found"
# branch — which must still resolve the project name correctly and exit 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../../hooks/session-start.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ── Fixture: bare .xcodeproj with the bundle-internal workspace, no .xcworkspace
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Foo/Foo.xcodeproj/project.xcworkspace"

# ── Run the hook, capturing output and exit code (don't let our own set -e abort)
set +e
output=$(CLAUDE_PROJECT_DIR="$tmp/Foo" bash "$HOOK" 2>&1)
status=$?
set -e

# ── Assertions ────────────────────────────────────────────────────────────────
[[ "$status" -eq 0 ]] || fail "expected exit 0, got $status (output: '$output')"

# Bug 1: project name must resolve to "Foo", never "project".
case "$output" in
    *"for Foo"*) ;;
    *) fail "expected message to name 'Foo', got: '$output'" ;;
esac
case "$output" in
    *"for project"*) fail "PROJECT_NAME wrongly resolved to 'project': '$output'" ;;
esac

printf 'PASS: session-start hook resolves bare .xcodeproj to "Foo" and exits 0\n'
