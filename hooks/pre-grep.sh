#!/usr/bin/env bash
# xcindex: pre-grep hook (PreToolUse: Grep)
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
# All external commands use || fallbacks so pipefail never fires an early exit.

# Claude Code sends a JSON envelope on stdin; Grep's arguments live under
# `tool_input`. plutil ships with macOS and parses JSON without a python3 start.
PAYLOAD=$(cat 2>/dev/null || true)
[[ -z "$PAYLOAD" ]] && exit 0

json_field() {
    printf '%s' "$PAYLOAD" | plutil -extract "$1" raw -o - - 2>/dev/null || true
}

GLOB=$(json_field tool_input.glob)
TYPE=$(json_field tool_input.type)
SEARCH_PATH=$(json_field tool_input.path)

shopt -s nocasematch
SWIFT_TARGETED=no
case "$GLOB" in *.swift|*.m|*.mm) SWIFT_TARGETED=yes ;; esac
case "$SEARCH_PATH" in *.swift|*.m|*.mm) SWIFT_TARGETED=yes ;; esac
[[ "$TYPE" == swift ]] && SWIFT_TARGETED=yes
shopt -u nocasematch

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
