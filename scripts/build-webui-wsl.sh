#!/usr/bin/env bash
# Build llama.cpp WebUI inside WSL for performance.
# Syncs source to WSL ext4 (faster IO), builds, copies artifacts back to Windows.

set -euo pipefail

WIN_SRC="/mnt/c/Users/yoho/Downloads/llama.cpp-mtp"
WSL_DIR="$HOME/llama.cpp-mtp"
WEBUI_DIR="$WSL_DIR/tools/ui"
DIST_DIR="$WSL_DIR/tools/ui/dist"
WIN_DIST="$WIN_SRC/tools/ui/dist"

echo "=== Syncing source to WSL ($WSL_DIR) ==="
rsync -av --delete \
  --exclude='node_modules' \
  --exclude='.svelte-kit' \
  --exclude='build*' \
  --exclude='.git' \
  --exclude='.cache' \
  "$WIN_SRC/" \
  "$WSL_DIR/"

echo "=== Installing npm dependencies ==="
npm --prefix "$WEBUI_DIR" install

echo "=== Building WebUI ==="
npm --prefix "$WEBUI_DIR" run build

echo "=== Copying artifacts back to Windows ==="
mkdir -p "$WIN_DIST"
rsync -av --delete \
  "$DIST_DIR/" \
  "$WIN_DIST/"

echo "=== Done ==="
echo "Updated files in: $WIN_DIST"
