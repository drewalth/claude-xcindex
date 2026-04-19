#!/usr/bin/env bash
# One-shot script to create the claude-xcindex issue labels. Requires
# `gh auth login`. Idempotent — existing labels are updated, missing
# ones are created. Safe to re-run.
#
# Usage:  ./scripts/setup-labels.sh [owner/repo]
# Default repo is inferred from the current git remote.

set -euo pipefail

REPO="${1:-}"

ensure_label() {
    local name="$1" color="$2" desc="$3"
    if gh label create "$name" --color "$color" --description "$desc" ${REPO:+--repo "$REPO"} 2>/dev/null; then
        echo "  created: $name"
    else
        gh label edit "$name" --color "$color" --description "$desc" ${REPO:+--repo "$REPO"} >/dev/null
        echo "  updated: $name"
    fi
}

# Standard triage / workflow labels (GitHub creates most of these by
# default but we reapply colors/descriptions for consistency).
ensure_label "bug"              "d73a4a" "Something isn't working"
ensure_label "enhancement"      "a2eeef" "New feature or request"
ensure_label "documentation"    "0075ca" "Docs-only improvement"
ensure_label "good first issue" "7057ff" "Low-friction starter tasks"
ensure_label "help wanted"      "008672" "Extra attention is needed"
ensure_label "question"         "d876e3" "Further information requested"
ensure_label "released"         "ededed" "Landed in a tagged release"

# Project-specific area labels — make it easy to filter by subsystem.
ensure_label "freshness"    "fbca04" "Index freshness / session-edit tracking"
ensure_label "index"        "1d76db" "IndexStoreDB queries or data shape"
ensure_label "mcp-protocol" "5319e7" "MCP server / JSON-RPC surface"
ensure_label "plugin"       "0e8a16" "Claude Code plugin packaging, hooks, skills"
ensure_label "ci"           "c2e0c6" "Continuous integration workflow"
ensure_label "dependencies" "0366d6" "Swift or GitHub Actions dependency updates"

echo
echo "Done. Verify with: gh label list ${REPO:+--repo \"$REPO\"}"
