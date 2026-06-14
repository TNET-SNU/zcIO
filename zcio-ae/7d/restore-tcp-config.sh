#!/bin/bash
# restore-tcp-config.sh — revert the sysctls that set_tcp_config.sh changed back
# to the values it saved (for the kernel linux/zcIO configs). No-op if there is
# no saved state (i.e. SPDK never changed anything this run).
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

SAVE="${TCP_SAVE:-/tmp/zcio-tcp-config.saved}"
if [[ -f "$SAVE" ]]; then
  sysctl -p "$SAVE" >/dev/null && echo "[restore-tcp] reverted TCP config from $SAVE"
  rm -f "$SAVE"
else
  echo "[restore-tcp] no saved TCP state — nothing to revert"
fi
