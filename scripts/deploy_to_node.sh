#!/bin/bash
# Sync customized APISIX files from this git repo to the installed APISIX directory.
# Run on each APISIX node. Assumes repo is checked out locally and APISIX is at /usr/local/apisix.

set -e

REPO_DIR="${1:-$(pwd)}"
APISIX_DIR="${APISIX_DIR:-/usr/local/apisix}"

if [ ! -d "$REPO_DIR/apisix" ]; then
    echo "ERROR: $REPO_DIR/apisix not found. Run inside repo root or pass repo path as arg."
    exit 1
fi

echo "Repo: $REPO_DIR"
echo "APISIX: $APISIX_DIR"
echo "---"

# Files to sync (relative to repo root)
FILES=(
    "apisix/plugins/ai-rate-limiting.lua"
    "apisix/plugins/prometheus/exporter.lua"
    "apisix/plugins/ai-drivers/ai-rate-limiting.lua"
    "apisix/plugins/ai-drivers/anthropic-self.lua"
    "apisix/plugins/ai-drivers/anthropic-vertex.lua"
    "apisix/plugins/ai-drivers/gemini-self.lua"
    "apisix/plugins/ai-drivers/openai-base.lua"
    "apisix/plugins/ai-drivers/openai-codex.lua"
    "apisix/plugins/ai-drivers/proxy-utils.lua"
    "apisix/plugins/ai-drivers/schema.lua"
    "apisix/plugins/ai-proxy/base.lua"
    "apisix/plugins/ai-proxy/schema.lua"
    "apisix/utils/google-cloud-oauth.lua"
)

for f in "${FILES[@]}"; do
    src="$REPO_DIR/$f"
    dst="$APISIX_DIR/$f"
    if [ -f "$src" ]; then
        sudo mkdir -p "$(dirname "$dst")"
        sudo cp "$src" "$dst"
        echo "[OK]   $f"
    else
        echo "[SKIP] $f (not in repo)"
    fi
done

echo "---"
echo "Reloading APISIX..."
sudo apisix reload
echo "Done."
