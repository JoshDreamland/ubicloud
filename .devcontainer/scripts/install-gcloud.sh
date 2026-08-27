#!/usr/bin/env bash
# Installs the Google Cloud CLI using Google's official installer script.
#
# Usage: bash .devcontainer/scripts/install-gcloud.sh
set -euo pipefail

INSTALL_ROOT="${GCLOUD_INSTALL_ROOT:-/opt}"
SDK_DIR="$INSTALL_ROOT/google-cloud-sdk"
LINK_DIR=/usr/local/bin

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

if command -v gcloud > /dev/null 2>&1; then
  echo "gcloud already installed at $(command -v gcloud): $(gcloud --version 2> /dev/null | head -1)"
  exit 0
fi

echo "=== Installing Google Cloud CLI into $SDK_DIR ==="

$SUDO mkdir -p "$INSTALL_ROOT"
curl -fsSL https://sdk.cloud.google.com \
  | $SUDO bash -s -- --disable-prompts --install-dir="$INSTALL_ROOT"

# Absolute path, not `gcloud`: the symlinks are created below, and bash may
# still have the failed lookup from the guard above cached.
[ -x "$SDK_DIR/bin/gcloud" ] || { echo "ERROR: installer did not produce $SDK_DIR/bin/gcloud" >&2; exit 1; }

for bin in gcloud gsutil bq; do
  [ -x "$SDK_DIR/bin/$bin" ] || continue
  $SUDO ln -sf "$SDK_DIR/bin/$bin" "$LINK_DIR/$bin"
done

echo "Installed: $("$SDK_DIR/bin/gcloud" --version | head -1)"
echo "Location:  $SDK_DIR (symlinked into $LINK_DIR)"
