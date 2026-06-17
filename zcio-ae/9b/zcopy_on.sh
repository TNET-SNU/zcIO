#!/bin/bash
# zcopy_on.sh — stream5 (initiator): enable NVMe/TCP receive zero-copy (zcIO).
# Sets the nvme_tcp module parameters. NOPASSWD-friendly self-exec sudo version
# of the parent ../zcopy_on.sh (same values, no inner sudo).
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

PAGES="${1:-8}"     # rx_zc_batch_pages: canonical 8 (=32KB) per other AE figs; 64 tested = no ratio change.
modprobe nvme_tcp 2>/dev/null || true
P=/sys/module/nvme_tcp/parameters
[[ -e "$P/enable_zerocopy"   ]] && echo 1       > "$P/enable_zerocopy"
[[ -e "$P/rx_zc_batch_pages" ]] && echo "$PAGES" > "$P/rx_zc_batch_pages"
[[ -e "$P/rx_zc_batch_flush" ]] && echo Y      > "$P/rx_zc_batch_flush"
[[ -e "$P/rx_zc_idle_us"     ]] && echo 200000 > "$P/rx_zc_idle_us"

echo "[zcopy_on] enable_zerocopy=$(cat "$P/enable_zerocopy" 2>/dev/null)" \
     "rx_zc_batch_pages=$(cat "$P/rx_zc_batch_pages" 2>/dev/null)" \
     "rx_zc_batch_flush=$(cat "$P/rx_zc_batch_flush" 2>/dev/null)" \
     "rx_zc_idle_us=$(cat "$P/rx_zc_idle_us" 2>/dev/null)"
