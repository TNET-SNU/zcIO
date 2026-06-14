#!/bin/bash
# set-irq-affinity.sh — spread the mlx5 NIC RX IRQs round-robin across the
# currently-ONLINE CPUs, and stop irqbalance so it can't undo it.
#
# Re-run after every cpu-limit change: offlining cores makes the kernel collapse
# those cores' IRQs onto cpu0, so without re-pinning the RX work piles on core 0
# and the other cores idle. (Adapted from jonghyeon's set_irq_affinity.sh —
# NOPASSWD self-exec, targets the online-cpu set instead of 0..nproc-1.)
#
#   Usage:  sudo ./set-irq-affinity.sh
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

NICS=(${NICS:-ens2np0 ens3np0})

# irqbalance fights manual affinity — stop it.
systemctl stop irqbalance 2>/dev/null || true

# Expand /sys/.../cpu/online ("0-3,8" -> 0 1 2 3 8) into an array.
ONLINE=()
IFS=',' read -ra parts < /sys/devices/system/cpu/online
for p in "${parts[@]}"; do
  if [[ "$p" == *-* ]]; then
    for c in $(seq "${p%-*}" "${p#*-}"); do ONLINE+=("$c"); done
  else
    ONLINE+=("$p")
  fi
done
n=${#ONLINE[@]}
echo "[set-irq] online CPUs (${n}): ${ONLINE[*]}"

for nic in "${NICS[@]}"; do
  [[ -e "/sys/class/net/$nic/device" ]] || { echo "  WARN: $nic absent"; continue; }
  dev="$(readlink -f "/sys/class/net/$nic/device")"
  [[ -d "$dev/msi_irqs" ]] || { echo "  WARN: $nic has no msi_irqs"; continue; }
  i=0
  for irq in $(ls "$dev/msi_irqs" | sort -n); do
    [[ -w "/proc/irq/$irq/smp_affinity_list" ]] || continue
    echo "${ONLINE[i % n]}" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
    i=$((i+1))
  done
  echo "  $nic: pinned $i IRQs round-robin across ${n} online CPUs"
done
