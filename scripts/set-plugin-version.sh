#!/usr/bin/env bash
# Write a release version into .claude-plugin/plugin.json.
#
# Claude Code caches an installed plugin under a directory named for the
# `version` field of .claude-plugin/plugin.json, and `claude plugin update`
# re-copies the marketplace clone only when that field advertises something
# newer. The field is the plugin's cache key, not decoration.
#
# It used to be hand-maintained, and it drifted: upstream tags v3.0.0 and
# v3.0.2 both shipped a manifest reading 1.1.0, and this fork sat at 1.2.3
# with a newest release of v1.2.1. The failure that exposed it: a merged fix
# plus a published release still left every installed copy running the old
# binary, because the advertised version never moved and so `plugin update`
# was a permanent no-op. semantic-release now calls this from its `prepare`
# step, so the manifest always matches the tag being cut.
#
# Usage: scripts/set-plugin-version.sh <version>

set -euo pipefail

version="${1:-}"
[[ -n "$version" ]] || {
    echo "usage: ${0##*/} <version>" >&2
    exit 2
}

# Reject anything that is not semver. A malformed value would be baked into the
# manifest and break resolution at install time, where the error surfaces far
# from its cause.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)*$ ]] || {
    echo "error: '${version}' is not a valid semver version" >&2
    exit 2
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${REPO_ROOT}/.claude-plugin/plugin.json"
[[ -f "$manifest" ]] || {
    echo "error: ${manifest} not found" >&2
    exit 1
}

# node rather than jq or sed: the release job already guarantees it via
# actions/setup-node, it parses the manifest instead of pattern-matching it,
# and JSON.stringify preserves key order so the diff stays one line.
node -e '
const fs = require("fs");
const [manifest, version] = process.argv.slice(1);
const json = JSON.parse(fs.readFileSync(manifest, "utf8"));
json.version = version;
fs.writeFileSync(manifest, JSON.stringify(json, null, 2) + "\n");
' "$manifest" "$version"

echo "plugin.json version -> ${version}"
