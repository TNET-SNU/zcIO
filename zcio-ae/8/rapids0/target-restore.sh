#!/usr/bin/env bash
# target-restore.sh — restore rapids0 to a clean baseline after the sweep:
#   1) bring every CPU core back online              (undo cpu_off.sh)
#   2) reload mlx5: rmmod mlx5_ib + mlx5_core (and the other deps so the
#      core can unload), then modprobe ONLY mlx5_core back
#   3) re-init the NICs + nvmet target               (nvmet-9100.sh)
#
# Staged to $RAPIDS0_DIR on the target by all_in_one.sh, run via NOPASSWD sudo.
#   Usage:  sudo ./target-restore.sh
set -uo pipefail

if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi

HERE="$(dirname "$(readlink -f "$0")")"

echo "[restore] 1/3 bringing all CPU cores online"
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  id="${cpu##*/cpu}"
  [[ "${id}" == "0" ]] && continue
  [[ -w "${cpu}/online" ]] || continue
  echo 1 > "${cpu}/online"
done
echo "[restore] online CPUs: $(nproc)"

echo "[restore] 2/3 reloading mlx5 (rmmod deps + core, modprobe core only)"
# mlx5_ib (+ vdpa/fwctl, if present) hold references on mlx5_core; drop them
# first so mlx5_core can unload. Absent modules are ignored.
modprobe -r mlx5_ib mlx5_vdpa mlx5_fwctl mlx5_core 2>/dev/null || \
  modprobe -r mlx5_ib mlx5_core 2>/dev/null || true
modprobe mlx5_core
sleep 2   # let the netdevs (ens17np0/ens19np0) re-enumerate

echo "[restore] 3/3 re-init NICs + nvmet target (nvmet-9100.sh)"
"${HERE}/nvmet-9100.sh" --reset
# nvmet-9100.sh assigns the data IPs but leaves MTU at the driver default;
# restore the normal 9000 baseline (matches init.sh) on both NICs.
for i in ens17np0 ens19np0; do
  [[ -e "/sys/class/net/${i}" ]] && ip link set "${i}" mtu 9000 up || true
done

echo "[restore] done. rapids0 is back to the all-cores / mlx5_core / nvmet baseline."
