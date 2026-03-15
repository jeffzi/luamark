#!/usr/bin/env bash
# Copy luamark.lua into the Love2D project so it can be required.
# Run from the repository root: bash tests/love2d/setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cp "$REPO_ROOT/src/luamark.lua" "$SCRIPT_DIR/luamark.lua"

echo "Copied src/luamark.lua -> tests/love2d/luamark.lua"
echo "Run: love tests/love2d"
