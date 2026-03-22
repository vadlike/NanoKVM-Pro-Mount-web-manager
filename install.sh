#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-vadlike}"
REPO_NAME="${REPO_NAME:-NanoKVM-Pro-Mount-web-manager}"
REPO_BRANCH="${REPO_BRANCH:-main}"
INSTALL_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/scripts/install-tinyfilemanager.sh"
TMP_SCRIPT="/tmp/nanokvm-pro-install.sh"

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
    return 0
  fi
  echo "curl or wget is required" >&2
  exit 1
}

fetch "${INSTALL_URL}" "${TMP_SCRIPT}"
chmod +x "${TMP_SCRIPT}"
exec bash "${TMP_SCRIPT}" "$@"
