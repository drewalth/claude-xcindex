#!/usr/bin/env bash
# Regression tests for hooks/session-start.sh
#
# Guards issue #9 (the hook aborted with exit 1 and no output on projects with a
# bare *.xcodeproj and no standalone *.xcworkspace) and locks in the surrounding
# behavior the fix depends on:
#   1. find must skip the bundle-internal MyApp.xcodeproj/project.xcworkspace,
#      so PROJECT_NAME resolves to "MyApp", not "project".
#   2. the empty DerivedData glob must not trip `set -e`/pipefail before the
#      "no index found" guard can print and exit 0.
#   3. the trap backstop must force exit 0 even on an abnormal abort, while
#      still emitting a diagnostic line (so a broken freshness signal is visible
#      rather than silently absent).
#   + the standalone-.xcworkspace, parent-dir, current-index, and stale-file
#     branches the fix must not regress.
#
# Self-contained and deterministic: HOME and PATH are pinned per-case so no
# assertion depends on the developer's real DerivedData or Xcode preferences.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../../hooks/session-start.sh"

PASS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

# A PATH shim whose `defaults` always reports "no custom DerivedData location",
# so DERIVED_DATA_BASE deterministically falls back to $HOME/Library/... and the
# tests never read (or depend on) the developer's real Xcode preferences.
SHIM="$root/shim"
mkdir -p "$SHIM"
cat > "$SHIM/defaults" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$SHIM/defaults"

# run_hook <project_dir> [home] [path]
# Runs the hook with HOME pinned into the sandbox and the shim ahead of PATH,
# capturing stdout+stderr into $output and the exit code into $status. No
# `set -e` toggling needed — errexit is off in this harness, so a non-zero hook
# exit just lands in $status instead of aborting the test.
run_hook() {
    local proj_dir="$1" home="${2:-$root/home}" path="${3:-$SHIM:$PATH}"
    mkdir -p "$home"
    output=$(CLAUDE_PROJECT_DIR="$proj_dir" HOME="$home" PATH="$path" bash "$HOOK" 2>&1)
    status=$?
}

# ── Case 1: bare .xcodeproj — issue #9, both root causes ─────────────────────
# A bundle-internal project.xcworkspace and no standalone workspace. Asserting
# the "No Xcode index found for Foo" string proves BOTH fixes: the name resolved
# to "Foo" (not "project"), AND control reached the no-index guard past the
# empty `ls ... || true` glob without `set -e` aborting first.
p1="$root/case1/Foo"
mkdir -p "$p1/Foo.xcodeproj/project.xcworkspace"
run_hook "$p1"
[[ "$status" -eq 0 ]] || fail "case1: expected exit 0, got $status (output: '$output')"
case "$output" in
    *"No Xcode index found for Foo"*) ;;
    *) fail "case1: expected 'No Xcode index found for Foo', got: '$output'" ;;
esac
case "$output" in
    *"for project"*) fail "case1: PROJECT_NAME wrongly resolved to 'project': '$output'" ;;
esac
ok 'bare .xcodeproj resolves to "Foo" and reaches the no-index guard (exit 0)'

# ── Case 2: standalone .xcworkspace must NOT be excluded ──────────────────────
# The fix added `! -path "*.xcodeproj/*"` to the workspace find. Confirm a real
# top-level Bar.xcworkspace (the CocoaPods/SPM layout) is still selected even
# when a sibling .xcodeproj bundle is present — i.e. the exclusion is not
# over-broad.
p2="$root/case2/Bar"
mkdir -p "$p2/Bar.xcworkspace"
mkdir -p "$p2/Bar.xcodeproj/project.xcworkspace"
run_hook "$p2"
[[ "$status" -eq 0 ]] || fail "case2: expected exit 0, got $status (output: '$output')"
case "$output" in
    *"for Bar"*) ;;
    *) fail "case2: standalone .xcworkspace should resolve to 'Bar', got: '$output'" ;;
esac
ok 'standalone .xcworkspace still selected → "Bar" (exclusion not over-broad)'

# ── Case 3: project located one level up from CWD ────────────────────────────
# find_project also searches dirname(CWD). Run from a Sources/ subdir and expect
# the parent's Baz.xcodeproj to be found.
p3="$root/case3/Baz"
mkdir -p "$p3/Baz.xcodeproj/project.xcworkspace" "$p3/Sources"
run_hook "$p3/Sources"
[[ "$status" -eq 0 ]] || fail "case3: expected exit 0, got $status (output: '$output')"
case "$output" in
    *"for Baz"*) ;;
    *) fail "case3: project one level up should resolve to 'Baz', got: '$output'" ;;
esac
ok 'project one level up from CWD → "Baz"'

# ── Case 4: trap backstop fires on an abnormal abort ─────────────────────────
# Shim `shasum` to fail; under set -e/pipefail the state-file hash aborts the
# script mid-stream. The trap must still force exit 0 AND emit its diagnostic,
# rather than vanishing silently.
BROKEN="$root/broken"
mkdir -p "$BROKEN"
cat > "$BROKEN/shasum" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
chmod +x "$BROKEN/shasum"
p4="$root/case4/Qux"
mkdir -p "$p4/Qux.xcodeproj/project.xcworkspace"
run_hook "$p4" "$root/home" "$BROKEN:$SHIM:$PATH"
[[ "$status" -eq 0 ]] || fail "case4: trap must force exit 0 on abnormal abort, got $status (output: '$output')"
case "$output" in
    *"exited unexpectedly"*) ;;
    *) fail "case4: expected trap diagnostic on abort, got: '$output'" ;;
esac
ok 'trap backstop forces exit 0 and emits a diagnostic on abnormal abort'

# ── Case 5: populated index, no newer sources → "current" branch ─────────────
home5="$root/home5"
p5="$root/case5/Cur"
mkdir -p "$p5/Cur.xcodeproj/project.xcworkspace"
mkdir -p "$home5/Library/Developer/Xcode/DerivedData/Cur-abc123/Index.noindex/DataStore"
run_hook "$p5" "$home5"
[[ "$status" -eq 0 ]] || fail "case5: expected exit 0, got $status (output: '$output')"
case "$output" in
    *"Index is current for Cur"*) ;;
    *) fail "case5: expected 'Index is current for Cur', got: '$output'" ;;
esac
ok 'populated index with no newer sources → "Index is current"'

# ── Case 6: stale index → count + ellipsis truncation (>5 files) ─────────────
home6="$root/home6"
p6="$root/case6/Stale"
ds6="$home6/Library/Developer/Xcode/DerivedData/Stale-xyz/Index.noindex/DataStore"
mkdir -p "$p6/Stale.xcodeproj/project.xcworkspace" "$ds6"
touch -t 200001010000 "$ds6"             # backdate the index so sources count as newer
for i in 1 2 3 4 5 6 7; do : > "$p6/File$i.swift"; done
run_hook "$p6" "$home6"
[[ "$status" -eq 0 ]] || fail "case6: expected exit 0, got $status (output: '$output')"
case "$output" in
    *"7 Swift file(s) newer than the index for Stale"*) ;;
    *) fail "case6: expected stale count of 7 for Stale, got: '$output'" ;;
esac
case "$output" in
    *", ..."*) ;;
    *) fail "case6: expected ', ...' ellipsis when >5 files are stale, got: '$output'" ;;
esac
ok 'stale index reports count and truncates the file list with ellipsis'

# ── Case 7: vendored dependency trees must be pruned ─────────────────────────
# SPM checkouts under .build (and Pods/node_modules) are not the user's code and
# are not what "build in Xcode" would refresh, so counting them is both noise and
# — at ~35k files on a real monorepo — the dominant cost of this hook. Only the
# first-party file may be counted.
home7="$root/home7"
p7="$root/case7/Pruned"
ds7="$home7/Library/Developer/Xcode/DerivedData/Pruned-xyz/Index.noindex/DataStore"
mkdir -p "$p7/Pruned.xcodeproj/project.xcworkspace" "$ds7"
mkdir -p "$p7/.build/checkouts/grdb/Sources" "$p7/Pods/Alamofire" "$p7/node_modules/pkg"
touch -t 200001010000 "$ds7"             # backdate the index so sources count as newer
: > "$p7/Mine.swift"
: > "$p7/.build/checkouts/grdb/Sources/Vendored.swift"
: > "$p7/Pods/Alamofire/Vendored.swift"
: > "$p7/node_modules/pkg/Vendored.swift"
run_hook "$p7" "$home7"
[[ "$status" -eq 0 ]] || fail "case7: expected exit 0, got $status (output: '$output')"
case "$output" in
    *"1 Swift file(s) newer than the index for Pruned"*) ;;
    *) fail "case7: expected exactly 1 stale file (vendored trees pruned), got: '$output'" ;;
esac
case "$output" in
    *Vendored.swift*) fail "case7: vendored file leaked into the stale list: '$output'" ;;
esac
ok 'vendored trees (.build/Pods/node_modules) are pruned from the stale scan'

# ── Case 8: relative custom DerivedData location + unhashed container ────────
# IDECustomDerivedDataLocation can be relative ("DerivedData"), resolved by
# Xcode against the project/workspace's directory, and the resulting
# container is named exactly "<ProjectName>" (no hash suffix).
SHIM8="$root/shim8"
mkdir -p "$SHIM8"
cat > "$SHIM8/defaults" <<'EOF'
#!/usr/bin/env bash
echo "DerivedData"
exit 0
EOF
chmod +x "$SHIM8/defaults"

p8="$root/case8/Handled"
mkdir -p "$p8/Handled.xcworkspace"
ds8="$p8/DerivedData/Handled/Index.noindex/DataStore"
mkdir -p "$ds8"
cat > "$p8/DerivedData/Handled/info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>WorkspacePath</key><string>${p8}/Handled.xcworkspace</string></dict></plist>
EOF
run_hook "$p8" "$root/home8" "$SHIM8:$SHIM:$PATH"
[[ "$status" -eq 0 ]] || fail "case8: expected exit 0, got $status (output: '$output')"
case "$output" in
    *"Index is current for Handled"*) ;;
    *) fail "case8: expected 'Index is current for Handled', got: '$output'" ;;
esac
ok 'relative custom DerivedData location resolves to the unhashed container'

# ── Case 9: WorkspacePath provenance beats newest-mtime ──────────────────────
# A newer, wrong-provenance container in the default base must not shadow the
# correct (but older-mtime) container found via the relative custom location.
SHIM9="$SHIM8"

p9="$root/case9/Prov"
mkdir -p "$p9/Prov.xcworkspace"
home9="$root/home9"

# Right container: relative custom base, correct WorkspacePath, FRESH DataStore.
ds9_right="$p9/DerivedData/Prov/Index.noindex/DataStore"
mkdir -p "$ds9_right"
cat > "$p9/DerivedData/Prov/info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>WorkspacePath</key><string>${p9}/Prov.xcworkspace</string></dict></plist>
EOF

# Wrong container: default base, mismatching WorkspacePath, BACKDATED DataStore,
# but a NEWER directory mtime than the right container so a pure-mtime pick
# would choose it in error.
ds9_wrong_dir="$home9/Library/Developer/Xcode/DerivedData/Prov-otherhash"
ds9_wrong="$ds9_wrong_dir/Index.noindex/DataStore"
mkdir -p "$ds9_wrong"
cat > "$ds9_wrong_dir/info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>WorkspacePath</key><string>/some/other/Other.xcworkspace</string></dict></plist>
EOF
touch -t 200001010000 "$ds9_wrong"
touch "$ds9_wrong_dir"   # newer directory mtime than the right container

# A source file newer than the wrong (backdated) store but older than the
# right (fresh) store — proves the correct container was actually used.
touch -t 201001010000 "$p9/F.swift"

run_hook "$p9" "$home9" "$SHIM9:$SHIM:$PATH"
[[ "$status" -eq 0 ]] || fail "case9: expected exit 0, got $status (output: '$output')"
case "$output" in
    *"Index is current for Prov"*) ;;
    *) fail "case9: expected 'Index is current for Prov' (provenance must beat mtime), got: '$output'" ;;
esac
ok 'WorkspacePath provenance selects the correct container over a newer-mtime mismatch'

printf '\nAll %d session-start hook checks passed.\n' "$PASS"
