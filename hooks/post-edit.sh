#!/usr/bin/env bash
# claude-xcindex: post-edit hook (PostToolUse: Edit|Write|MultiEdit)
#
# When Claude edits a Swift/ObjC source file, emit a note so Claude knows
# that the index may be stale for that file's symbols.
#
# The CLAUDE_TOOL_RESULT environment variable contains the tool result JSON.
# We parse it to find the edited file path.
#
# Exit 0 always — this is informational only.

set -euo pipefail

# Parse the file path from the tool result or tool input JSON
# Claude Code sets these environment variables for PostToolUse hooks:
#   CLAUDE_TOOL_NAME       — e.g. "Edit"
#   CLAUDE_TOOL_INPUT      — JSON of the tool input
#   CLAUDE_TOOL_OUTPUT     — JSON of the tool output

TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"

if [[ -z "$TOOL_INPUT" ]]; then
    exit 0
fi

# Extract file_path from tool input JSON
FILE_PATH=$(echo "$TOOL_INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('file_path', data.get('path', '')))
except:
    pass
" 2>/dev/null || true)

if [[ -z "$FILE_PATH" ]]; then
    exit 0
fi

# Only care about Swift and ObjC source files
case "$FILE_PATH" in
    *.swift|*.m|*.mm|*.h)
        BASENAME=$(basename "$FILE_PATH")
        echo "[xcindex] '${BASENAME}' was edited this session — xcindex results for its symbols may be stale until the project is rebuilt in Xcode."
        ;;
esac

exit 0
