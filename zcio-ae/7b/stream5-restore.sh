#!/bin/bash
# stream5-restore.sh (fig-7b, write path) — restore the INITIATOR (stream5) after
# the run. stream5 is the SENDER and is NOT core-limited in the write figures, so
# this just brings any (defensively) offlined cores back, re-applies the data
# plane (buffer.sh + stream5-net.sh, which reloads mlx5 with the hw-gro recipe),
# and resets nvme_pdu_align to 0. The TARGET (rapids0) is restored separately by
# all-in-one via target-restore.sh.
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
DIR="$(dirname "$SCRIPT_PATH")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

echo "[restore] 1/2 ensuring all CPU cores online"
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  id="${cpu##*/cpu}"
  [[ "$id" == "0" ]] && continue
  [[ -w "$cpu/online" ]] || continue
  echo 1 > "$cpu/online"
done
echo "[restore] online CPUs: $(nproc)"
sleep 2

echo "[restore] 2/2 reload mlx5 + re-apply net + pdu_align 0"
"$DIR/buffer.sh"
"$DIR/stream5-net.sh"
[[ -e /proc/sys/net/ipv4/nvme_pdu_align ]] && sysctl -w net.ipv4.nvme_pdu_align=0 || true
echo "[restore] done."
