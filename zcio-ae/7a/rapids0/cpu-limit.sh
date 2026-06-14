#!/bin/bash
# cpu-limit.sh (rapids0) — keep exactly N CPU cores online (cpu0..N-1), offline
# the rest. Mirror of the initiator cpu-limit.sh, used to core-limit the TARGET
# for the write figures. Run via NOPASSWD sudo over SSH (assumes already root).
#
#   Usage:  ./cpu-limit.sh <N>
#
# For the kernel configs we connect the subsystems ONCE at full cores and only
# ever OFFLINE cores afterward (onlining cores under live multi-queue NVMe/TCP
# re-triggers the connect path which fails with some CPUs offlined).
set -uo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
N="${1:?usage: cpu-limit.sh <N>}"
[[ "$N" =~ ^[0-9]+$ && "$N" -ge 1 ]] || { echo "ERROR: N must be a positive integer" >&2; exit 1; }

for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    id="${cpu##*/cpu}"
    [[ "$id" == "0" ]] && continue
    [[ -w "$cpu/online" ]] || continue
    if [[ "$id" -lt "$N" ]]; then echo 1 > "$cpu/online"; else echo 0 > "$cpu/online"; fi
done
echo "[cpu-limit] requested N=$N  online CPUs: $(nproc)  ($(cat /sys/devices/system/cpu/online))"
