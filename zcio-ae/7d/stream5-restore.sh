#!/bin/bash
# stream5-restore.sh — restore the INITIATOR (stream5) after the fig-7d run:
#   1) bring every CPU core back online   (undo cpu-limit.sh)
#   2) re-apply the data-plane (buffer.sh + stream5-net.sh) and zcopy off
#
# stream5-net.sh reloads mlx5 itself (with the hw-gro-first recipe), so running
# it here — after the cores are back online — gives a clean full-core driver
# with rx-gro-hw on.
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
DIR="$(dirname "$SCRIPT_PATH")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

echo "[restore] 1/2 bringing all CPU cores online"
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  id="${cpu##*/cpu}"
  [[ "$id" == "0" ]] && continue
  [[ -w "$cpu/online" ]] || continue
  echo 1 > "$cpu/online"
done
echo "[restore] online CPUs: $(nproc)"
sleep 2   # let mlx5 re-add channels for the cores that came back

echo "[restore] 2/2 reload mlx5 + re-apply net + zcopy off"
"$DIR/buffer.sh"
"$DIR/stream5-net.sh"
"$DIR/zcopy_off.sh"
echo "[restore] done."
