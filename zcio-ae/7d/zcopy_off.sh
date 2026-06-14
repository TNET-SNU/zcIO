#!/bin/bash
# zcopy_off.sh — stream5 (initiator): disable NVMe/TCP receive zero-copy.
# Sets the nvme_tcp module parameters (baseline "linux" path). NOPASSWD-friendly
# self-exec sudo version of the parent ../zcopy_off.sh (same values, no inner sudo).
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

modprobe nvme_tcp 2>/dev/null || true
P=/sys/module/nvme_tcp/parameters
[[ -e "$P/enable_zerocopy"   ]] && echo 0 > "$P/enable_zerocopy"
[[ -e "$P/rx_zc_batch_flush" ]] && echo N > "$P/rx_zc_batch_flush"

echo "[zcopy_off] enable_zerocopy=$(cat "$P/enable_zerocopy" 2>/dev/null) rx_zc_batch_flush=$(cat "$P/rx_zc_batch_flush" 2>/dev/null)"
