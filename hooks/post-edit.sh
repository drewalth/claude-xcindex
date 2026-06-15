#!/usr/bin/env bash
# xcindex: post-edit hook (PostToolUse: Edit|Write|MultiEdit)
#
# When Claude edits a Swift/ObjC source file, append its absolute path to
# the session state file. The MCP server (xcindex) reads this file on each
# query and annotates results for symbols defined in those files as "may be
# stale since the index was last built."
#
# State file location is derived from CLAUDE_PROJECT_DIR (or pwd) and must
# match the path computed by service/Sources/xcindex/Freshness.swift#stateFilePath.
#
# Exit 0 always — this is informational only; a failure here must not block
# the tool.

set -euo pipefail

# Backstop the "Exit 0 always" contract: a failure here must never block the
# tool that triggered this hook.
trap 'exit 0' EXIT

TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"
[[ -z "$TOOL_INPUT" ]] && exit 0

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

# Absolutize: the MCP server compares against absolute paths from the index.
if [[ "$FILE_PATH" != /* ]]; then
    FILE_PATH="$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd)/$(basename "$FILE_PATH")"
fi

# Derive state file path — must match Freshness.swift#stateFilePath
CWD="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TMP="${TMPDIR:-/tmp}"
TMP="${TMP%/}"
HASH=$(printf '%s' "$CWD" | shasum -a 1 | cut -c1-12)
STATE_FILE="${TMP}/xcindex-edited-${HASH}.txt"

# Append unless already recorded this session.
if [[ ! -f "$STATE_FILE" ]] || ! grep -qxF "$FILE_PATH" "$STATE_FILE" 2>/dev/null; then
    echo "$FILE_PATH" >> "$STATE_FILE"
fi

BASENAME=$(basename "$FILE_PATH")
echo "[xcindex] '${BASENAME}' was edited — xcindex results for its symbols may be stale until the project is rebuilt in Xcode."

exit 0
