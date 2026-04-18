#!/usr/bin/env bash
# Build script for claude-xcindex
#
# Compiles the TypeScript MCP server and the Swift binary.
# Run this once before installing the plugin, and again after pulling updates.
#
# Usage:
#   ./build.sh           # release build (default)
#   ./build.sh --debug   # debug build

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="${PLUGIN_DIR}/mcp"
SWIFT_DIR="${MCP_DIR}/swift-service"

MODE="release"
if [[ "${1:-}" == "--debug" ]]; then
    MODE="debug"
fi

echo "==> Building claude-xcindex (${MODE} mode)"
echo ""

# ── TypeScript MCP server ────────────────────────────────────────────────────

echo "==> [1/2] Building TypeScript MCP server..."
cd "$MCP_DIR"

if ! command -v node &>/dev/null; then
    echo "ERROR: node not found. Install Node.js 18+ first."
    exit 1
fi

npm install --silent
npm run build

echo "    TypeScript build complete: mcp/dist/server.js"
echo ""

# ── Swift service ─────────────────────────────────────────────────────────────

echo "==> [2/2] Building Swift service..."
cd "$SWIFT_DIR"

if ! command -v swift &>/dev/null; then
    echo "ERROR: swift not found. Install Xcode command-line tools first."
    exit 1
fi

if [[ "$MODE" == "release" ]]; then
    swift build -c release 2>&1
    BINARY_PATH=".build/release/xcindex"
    # The symlink .build/release → .build/arm64-apple-macosx/release is created by SPM
    if [[ ! -f "$BINARY_PATH" ]]; then
        # Fallback: find it in the arch-specific directory
        BINARY_PATH=$(find .build -name xcindex -type f | grep release | head -1)
    fi
else
    swift build 2>&1
    BINARY_PATH=".build/debug/xcindex"
fi

echo "    Swift build complete: mcp/swift-service/${BINARY_PATH}"
echo ""

# ── Verify ───────────────────────────────────────────────────────────────────

echo "==> Verifying binary..."
RESULT=$(echo '{"op":"status","indexStorePath":"/nonexistent"}' \
    | "${SWIFT_DIR}/${BINARY_PATH}" 2>/dev/null)

if echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'status' in d or 'error' in d else 1)" 2>/dev/null; then
    echo "    Binary responds to JSON-RPC: OK"
else
    echo "    WARNING: Binary did not return expected JSON. Check the build output above."
fi

echo ""
echo "==> Build complete."
echo ""
echo "To install this plugin locally:"
echo "  /plugin install ${PLUGIN_DIR}"
echo ""
echo "Or add it to Claude Code settings.json manually:"
cat <<EOF
  "mcpServers": {
    "xcindex": {
      "command": "node",
      "args": ["${MCP_DIR}/dist/server.js"]
    }
  }
EOF
