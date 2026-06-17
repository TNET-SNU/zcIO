#!/bin/bash
# set-cores.sh (stream5, fig-9a) — single-core helper for the initiator.
#
#   ./set-cores.sh single   # offline every CPU but cpu0  (1 online core)
#   ./set-cores.sh all      # bring all CPUs back online
#
# Used to pin the initiator to ONE core BEFORE `nvme connect`, so nvme-tcp
# negotiates only as many IO queues / TCP streams as there are online CPUs
# (= 1). Connecting at full cores and offlining afterwards leaves dead-core
# TCP streams, which hurts the single-core (esp. zerocopy) RocksDB read path.
# cpu0 cannot be offlined. Self-execs via sudo -n (NOPASSWD via deploy.sh).
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

MODE="${1:-single}"
case "$MODE" in
    single) want=0 ;;   # 0 = offline cpu1+
    all)    want=1 ;;   # 1 = online all
    *) echo "usage: $0 single|all"; exit 1 ;;
esac

for c in /sys/devices/system/cpu/cpu[0-9]*; do
    id="${c##*/cpu}"; [[ "$id" == "0" ]] && continue
    [[ -w "$c/online" ]] || continue
    echo "$want" > "$c/online"
done
echo "[set-cores] mode=$MODE  online CPUs now: $(nproc)  ($(cat /sys/devices/system/cpu/online))"
