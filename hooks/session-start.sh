#!/usr/bin/env bash
# claude-xcindex: session-start hook
#
# Checks the Xcode index freshness for any .xcodeproj / .xcworkspace in the
# current working directory and emits a short warning if the index is stale.
#
# This runs at session start (SessionStart hook). It injects context into
# the conversation so Claude knows whether it can trust index results.
#
# Exit 0 always — a missing index is informative, not fatal.

set -euo pipefail

CWD="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# ── Find the nearest .xcodeproj or .xcworkspace ──────────────────────────────

find_project() {
    # Look in CWD and one level up, prefer .xcworkspace over .xcodeproj
    for dir in "$CWD" "$(dirname "$CWD")"; do
        local ws
        ws=$(find "$dir" -maxdepth 2 -name "*.xcworkspace" ! -path "*/Pods/*" ! -path "*/.git/*" 2>/dev/null | head -1)
        if [[ -n "$ws" ]]; then echo "$ws"; return 0; fi
        local proj
        proj=$(find "$dir" -maxdepth 2 -name "*.xcodeproj" ! -path "*/.git/*" 2>/dev/null | head -1)
        if [[ -n "$proj" ]]; then echo "$proj"; return 0; fi
    done
    return 1
}

PROJECT=$(find_project 2>/dev/null || true)

if [[ -z "$PROJECT" ]]; then
    # No Xcode project found — nothing to check
    exit 0
fi

PROJECT_NAME=$(basename "$PROJECT" | sed 's/\.[^.]*$//')

# ── Locate the DerivedData folder ────────────────────────────────────────────

DERIVED_DATA_BASE="$HOME/Library/Developer/Xcode/DerivedData"

# Check for custom DerivedData path in Xcode preferences
CUSTOM_PATH=$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null || true)
if [[ -n "$CUSTOM_PATH" ]]; then
    DERIVED_DATA_BASE="$CUSTOM_PATH"
fi

DATA_STORE=$(
    ls -dt "${DERIVED_DATA_BASE}/${PROJECT_NAME}-"* 2>/dev/null \
    | head -1
)

if [[ -z "$DATA_STORE" || ! -d "$DATA_STORE/Index.noindex/DataStore" ]]; then
    echo "⚠️  [xcindex] No index found for ${PROJECT_NAME}." \
         "Build the project in Xcode to enable semantic symbol queries."
    exit 0
fi

INDEX_STORE="${DATA_STORE}/Index.noindex/DataStore"

# ── Check staleness: count Swift files newer than the DataStore mtime ────────

INDEX_MTIME=$(stat -f "%m" "$INDEX_STORE" 2>/dev/null || echo 0)
STALE_COUNT=0
STALE_FILES=()

while IFS= read -r -d '' f; do
    FILE_MTIME=$(stat -f "%m" "$f" 2>/dev/null || echo 0)
    if (( FILE_MTIME > INDEX_MTIME )); then
        STALE_COUNT=$((STALE_COUNT + 1))
        STALE_FILES+=("$(basename "$f")")
    fi
done < <(find "$CWD" -name "*.swift" -not -path "*/.git/*" -not -path "*/DerivedData/*" -print0 2>/dev/null)

# ── Emit context ─────────────────────────────────────────────────────────────

INDEX_DATE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$INDEX_STORE" 2>/dev/null || echo "unknown")

if (( STALE_COUNT == 0 )); then
    echo "[xcindex] Index is current for ${PROJECT_NAME} (last built ${INDEX_DATE})." \
         "xcindex_* tools are available for semantic symbol queries."
else
    NAMES="${STALE_FILES[*]:0:5}"
    echo "⚠️  [xcindex] ${STALE_COUNT} Swift file(s) newer than the index for ${PROJECT_NAME}" \
         "(last built ${INDEX_DATE}): ${NAMES}$(( ${#STALE_FILES[@]} > 5 )) && echo ' ...' || true)." \
         "Consider building in Xcode before running xcindex_* queries, or expect stale results."
fi

exit 0
