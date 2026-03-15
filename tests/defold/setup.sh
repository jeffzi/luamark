#!/usr/bin/env bash
# Copy luamark.lua into the Defold project so it can be required.
# Run from the repository root: bash tests/defold/setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cp "$REPO_ROOT/src/luamark.lua" "$SCRIPT_DIR/luamark.lua"

echo "Copied src/luamark.lua -> tests/defold/luamark.lua"
echo "Open tests/defold/ in Defold editor and build (Ctrl+B / Cmd+B)."
