#!/usr/bin/env bash
# fetch-fixture.sh: clone an external SwiftPM fixture at the SHA pinned
# in its ground-truth JSON, into a scratch directory, so the matching
# CoverageHarness can build + query a reproducible index.
#
# Supported fixtures (as of this commit): tca, swift-log.
# Add a new one by dropping tests/fixtures/<name>/<name>.json with an
# `upstream.{tag,sha}` block and `fixture_source` URL, then calling:
#   scripts/fetch-fixture.sh <name>
#
# Usage:
#   scripts/fetch-fixture.sh <fixture>                       # default clone target
#   scripts/fetch-fixture.sh <fixture> --path /path/to/dir   # override target
#
# Env:
#   <FIXTURE>_FIXTURE_DIR  — if set, overrides --path and the default.
#                            Name is uppercased and '-' -> '_'
#                            (e.g. swift-log -> SWIFT_LOG_FIXTURE_DIR).
#                            Pass the same value to `swift test` so the
#                            harness picks up the checkout.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -lt 1 ]]; then
    echo "usage: $(basename "$0") <fixture> [--path <dir>]" >&2
    exit 2
fi

FIXTURE="$1"
shift

FIXTURE_JSON="${PLUGIN_ROOT}/tests/fixtures/${FIXTURE}/${FIXTURE}.json"
if [[ ! -f "$FIXTURE_JSON" ]]; then
    echo "ERROR: $FIXTURE_JSON not found — has this fixture been seeded?" >&2
    exit 1
fi

# Parse pin + upstream URL out of the fixture JSON.
SHA=$(python3 -c "import json; print(json.load(open('$FIXTURE_JSON'))['upstream']['sha'])")
TAG=$(python3 -c "import json; print(json.load(open('$FIXTURE_JSON'))['upstream']['tag'])")
REPO=$(python3 -c "import json; print(json.load(open('$FIXTURE_JSON'))['fixture_source'])")

if [[ -z "$SHA" || -z "$TAG" || -z "$REPO" ]]; then
    echo "ERROR: upstream.sha / upstream.tag / fixture_source missing from $FIXTURE_JSON" >&2
    exit 1
fi

# Env-var override: <FIXTURE>_FIXTURE_DIR, with '-' -> '_'.
ENV_KEY="$(echo "$FIXTURE" | tr '[:lower:]-' '[:upper:]_')_FIXTURE_DIR"
TARGET="${!ENV_KEY:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path) TARGET="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    case "$(uname)" in
        Darwin) CACHE_BASE="$HOME/Library/Caches" ;;
        *)      CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}" ;;
    esac
    TARGET="$CACHE_BASE/claude-xcindex/${FIXTURE}-${TAG}"
fi

mkdir -p "$(dirname "$TARGET")"

if [[ -d "$TARGET/.git" ]]; then
    current=$(git -C "$TARGET" rev-parse HEAD 2>/dev/null || echo "")
    if [[ "$current" == "$SHA" ]]; then
        echo "Already at $SHA: $TARGET"
        echo "${ENV_KEY}=$TARGET"
        exit 0
    fi
    echo "Existing checkout at $TARGET is at $current, updating to $SHA..."
    git -C "$TARGET" fetch --depth 1 origin "$SHA"
    git -C "$TARGET" checkout -q "$SHA"
else
    echo "Cloning $FIXTURE $TAG ($SHA) into $TARGET..."
    git clone --depth 1 --branch "$TAG" "$REPO" "$TARGET"
    actual=$(git -C "$TARGET" rev-parse HEAD)
    if [[ "$actual" != "$SHA" ]]; then
        echo "WARNING: tag $TAG resolved to $actual, expected $SHA" >&2
        echo "Upstream may have re-tagged. Update $FIXTURE.json if this is intentional." >&2
    fi
fi

echo "${ENV_KEY}=$TARGET"
