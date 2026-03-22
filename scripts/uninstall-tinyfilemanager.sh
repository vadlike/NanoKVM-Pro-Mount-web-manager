#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="tinyfilemanager"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ARIA2_SERVICE_NAME="tinyfilemanager-aria2"
ARIA2_SERVICE_FILE="/etc/systemd/system/${ARIA2_SERVICE_NAME}.service"
INSTALL_DIR="/opt/tinyfilemanager"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
systemctl disable --now "${ARIA2_SERVICE_NAME}.service" 2>/dev/null || true
rm -f "${SERVICE_FILE}"
rm -f "${ARIA2_SERVICE_FILE}"
systemctl daemon-reload
systemctl reset-failed

rm -rf "${INSTALL_DIR}"

echo
echo "NanoKVM Pro removed."
echo "PHP and aria2 packages were left installed intentionally."
