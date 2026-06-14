#!/bin/bash
# cpu-limit.sh <N> — keep exactly N CPU cores online (cpu0 .. cpu(N-1)) and
# offline the rest. cpu0 can't be offlined, so N>=1.
#
#   Usage:  sudo ./cpu-limit.sh <N>
set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

N="${1:?usage: cpu-limit.sh <ncores>}"
[[ "$N" =~ ^[0-9]+$ && "$N" -ge 1 ]] || { echo "N must be an integer >= 1"; exit 1; }

for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  id="${cpu##*/cpu}"
  [[ "$id" == "0" ]] && continue          # cpu0 always online
  [[ -w "$cpu/online" ]] || continue
  if (( id < N )); then
    echo 1 > "$cpu/online"                 # online cpu1 .. cpu(N-1)
  else
    echo 0 > "$cpu/online"                  # offline cpuN ..
  fi
done

echo "[cpu-limit] target=$N  online CPUs: $(nproc)"
grep -H . /sys/devices/system/cpu/online
