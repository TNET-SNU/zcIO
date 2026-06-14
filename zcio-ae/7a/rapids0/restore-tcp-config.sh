#!/bin/bash
# restore-tcp-config.sh (rapids0) — revert the sysctls that set_tcp_config.sh
# changed back to the saved values (for the kernel linux/zcIO configs). No-op if
# there is no saved state. Run via NOPASSWD sudo over SSH (assumes already root).
set -uo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
SAVE="${TCP_SAVE:-/tmp/zcio-tcp-config.saved}"
if [[ -f "$SAVE" ]]; then
  sysctl -p "$SAVE" >/dev/null && echo "[restore-tcp] reverted TCP config from $SAVE"
  rm -f "$SAVE"
else
  echo "[restore-tcp] no saved TCP state — nothing to revert"
fi
