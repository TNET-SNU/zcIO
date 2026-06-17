#!/bin/bash
# set-cores.sh (stream5, fig-9b) — online-core count helper for the initiator.
#
#   ./set-cores.sh single   # offline every CPU but cpu0  (1 online core)
#   ./set-cores.sh all      # bring all CPUs back online
#   ./set-cores.sh <N>      # keep cpu0..cpu(N-1) online, offline the rest (N online cores)
#
# Sets the number of ONLINE cores. fig-9b's UNet3D sweep offlines cores (NOT
# taskset) so DLIO/MPI see exactly N CPUs — taskset crams all ranks onto a few
# cores and deadlocks at the epoch-end barrier; offlining does not.
# cpu0 cannot be offlined. Self-execs via sudo -n (NOPASSWD via deploy.sh).
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

MODE="${1:-single}"
case "$MODE" in
    single)      NCORES=1 ;;       # 1 online core (cpu0 only)
    all)         NCORES=0 ;;       # 0 = sentinel: online everything
    ''|*[!0-9]*) echo "usage: $0 single|all|<N>"; exit 1 ;;
    *)           NCORES="$MODE" ;; # numeric: N online cores
esac

for c in /sys/devices/system/cpu/cpu[0-9]*; do
    id="${c##*/cpu}"; [[ "$id" == "0" ]] && continue
    [[ -w "$c/online" ]] || continue
    if   [[ "$NCORES" == 0 ]]; then want=1     # all online
    elif (( id < NCORES ));    then want=1     # within the first N
    else                            want=0; fi # beyond N -> offline
    echo "$want" > "$c/online"
done
echo "[set-cores] mode=$MODE  online CPUs now: $(nproc)  ($(cat /sys/devices/system/cpu/online))"
