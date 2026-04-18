#!/usr/bin/env bash
# Build the xcindex Swift MCP server.
#
# Usage:
#   ./build.sh           # release build (default)
#   ./build.sh --debug   # debug build

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="${PLUGIN_DIR}/service"

MODE="release"
if [[ "${1:-}" == "--debug" ]]; then
    MODE="debug"
fi

if ! command -v swift &>/dev/null; then
    echo "ERROR: swift not found. Install Xcode command-line tools first." >&2
    exit 1
fi

echo "==> Building xcindex (${MODE})"
cd "$SERVICE_DIR"

if [[ "$MODE" == "release" ]]; then
    swift build -c release
    BINARY=".build/release/xcindex"
else
    swift build
    BINARY=".build/debug/xcindex"
fi

if [[ ! -f "$BINARY" ]]; then
    # SPM sometimes puts the binary in arch-specific dirs without the symlink
    BINARY=$(find .build -name xcindex -type f -perm -u+x | grep "/${MODE}/" | head -1)
fi

echo "==> Built: service/${BINARY}"
echo ""
echo "To install this plugin locally:"
echo "  /plugin install ${PLUGIN_DIR}"
