#!/bin/bash
# disconnect.sh (stream5) — disconnect all NVMe/TCP sessions. Self-execs sudo -n.
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
nvme disconnect-all >/dev/null 2>&1 || true
echo "[disconnect] all NVMe/TCP sessions disconnected"
