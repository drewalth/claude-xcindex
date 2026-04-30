#!/usr/bin/env bash
# xcindex: post-edit hook (PostToolUse: Edit|Write|MultiEdit)
#
# When Claude edits a Swift/ObjC source file, append its absolute path to
# the session state file. The MCP server (xcindex) reads this file on each
# query and annotates results for symbols defined in those files as "may be
# stale since the index was last built."
#
# State file location is derived from CLAUDE_PROJECT_DIR (or pwd) and must
# match the path computed by mcp/src/freshness.ts#stateFilePath.
#
# Exit 0 always — this is informational only; a failure here must not block
# the tool.

set -euo pipefail

TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"
[[ -z "$TOOL_INPUT" ]] && exit 0

# Extract file_path from tool input JSON
FILE_PATH=$(echo "$TOOL_INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('file_path', data.get('path', '')))
except Exception:
    pass
" 2>/dev/null || true)

[[ -z "$FILE_PATH" ]] && exit 0

# Only track Swift/ObjC source files
case "$FILE_PATH" in
    *.swift|*.m|*.mm|*.h) ;;
    *) exit 0 ;;
esac

# Resolve to absolute path (the MCP server compares against paths from the index)
if [[ "$FILE_PATH" != /* ]]; then
    FILE_PATH="$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd)/$(basename "$FILE_PATH")"
fi

# Derive state file path — must match freshness.ts#stateFilePath
CWD="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TMP="${TMPDIR:-/tmp}"
# Strip trailing slash from TMPDIR for a clean join
TMP="${TMP%/}"
HASH=$(printf '%s' "$CWD" | shasum -a 1 | cut -c1-12)
STATE_FILE="${TMP}/xcindex-edited-${HASH}.txt"

# Append if not already present
if [[ ! -f "$STATE_FILE" ]] || ! grep -qxF "$FILE_PATH" "$STATE_FILE" 2>/dev/null; then
    echo "$FILE_PATH" >> "$STATE_FILE"
fi

# Emit a single-line note for Claude
BASENAME=$(basename "$FILE_PATH")
echo "[xcindex] '${BASENAME}' was edited — xcindex results for its symbols may be stale until the project is rebuilt in Xcode."

exit 0
