#!/bin/bash
# set-irq-affinity.sh (rapids0) — spread the mlx5 NIC RX IRQs round-robin across
# the currently-ONLINE CPUs and stop irqbalance. Mirror of the initiator script,
# targeting the TARGET data NICs. Re-run after every cpu-limit change: offlining
# cores collapses their IRQs onto cpu0, so without re-pinning the RX work piles on
# core 0 and the other cores idle.
#
# Run via NOPASSWD sudo over SSH (assumes already root).
set -uo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
NICS=(${NICS:-ens17np0 ens19np0})
systemctl stop irqbalance 2>/dev/null || true
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
