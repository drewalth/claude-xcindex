#!/usr/bin/env bash
# claude-xcindex: pre-grep hook (PreToolUse: Grep)
#
# When Claude is about to grep Swift/ObjC source, surface a one-line
# reminder that xcindex_* tools are semantic — no false positives from
# comments, strings, or similarly-named symbols in other modules.
#
# Fires only when the Grep call has an explicit Swift/ObjC signal
# (glob ending in .swift/.m/.mm, type=swift, or a path ending in one of
# those extensions). Free-text searches (TODOs, log messages, literals)
# are unaffected. Non-blocking — the Grep always proceeds.
#
# Exit 0 always; on failure to inject context the tool still runs.

set -euo pipefail

# Tool input may arrive via the CLAUDE_TOOL_INPUT env var (used by the
# other hooks in this plugin) or via stdin (newer convention). Try both.
TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"
if [[ -z "$TOOL_INPUT" ]]; then
    TOOL_INPUT=$(cat 2>/dev/null || true)
fi
[[ -z "$TOOL_INPUT" ]] && exit 0

SWIFT_TARGETED=$(printf '%s' "$TOOL_INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
glob = (data.get('glob') or '').lower()
type_ = (data.get('type') or '').lower()
path = (data.get('path') or '').lower()
swift_exts = ('.swift', '.m', '.mm')
matched = (
    any(glob.endswith(ext) for ext in swift_exts)
    or type_ == 'swift'
    or path.endswith(swift_exts)
)
print('yes' if matched else 'no')
" 2>/dev/null || echo 'no')

[[ "$SWIFT_TARGETED" != "yes" ]] && exit 0

# Emit a non-blocking context message via the PreToolUse JSON contract.
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "[xcindex] Grep on Swift/ObjC source. For symbol-level questions (definitions, callers, references, overrides, conformances, file blast-radius) the xcindex MCP tools and skills give semantic results — no false positives from comments, strings, or similarly-named symbols in other modules. Skills available: swift-find-references (callers of a symbol), swift-blast-radius (file-level dependents + covering tests), swift-refactor-plan (preview a rename or refactor before committing), swift-rename-symbol (execute a committed rename). Continue with Grep only if this is a true text search (TODO comments, log messages, string literals)."
  }
}
JSON
exit 0
