#!/bin/bash
# connect.sh (stream5, fig-9b) — connect the 4 NVMe/TCP subsystems that fig-9b's
# MLPerf / RocksDB workloads run against.
#
# fig-9b testbed (per the paper): four NVMe drives exported over ONE ConnectX-7
# 400 GbE NIC. That is exactly fig-8's single-NIC layout:
#
#   stream5 ens2np0 (10.3.95.5)  <->  rapids0 ens17np0 (10.3.95.10)
#   subsystems: nvmet-ens17np0-nvme{6,7,8,9}n1   (4 namespaces)
#
# After this script, the 4 target namespaces appear locally as /dev/nvmeXn1
# (multipath head devices) and you can point your MLPerf / RocksDB scripts at
# them. This script is setup-only: it does NOT run any workload.
#
#   Usage:  ./connect.sh [--expect N] [NQN ...]
#     ./connect.sh                                  # default 4-subsystem layout
#     ./connect.sh --expect 4 nvmet-ens17np0-fig9a  # single subsystem, 4 ns
# NQNs/EXPECT are passed as ARGS (not env) because this script self-execs via
# `sudo -n`, which strips the environment — args survive the re-exec, env does not.
# Self-execs via sudo -n (NOPASSWD installed by deploy.sh).
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
cd "$(dirname "$SCRIPT_PATH")"

TADDR="${TADDR:-10.3.95.10}"            # target NIC IP (rapids0 ens17np0)
DATA_IP="${DATA_IP:-10.3.95.5}"         # initiator IP on the matching NIC
TSVC="${TSVC:-4420}"
NUM_IO_QUEUE="${NUM_IO_QUEUE:-}"        # empty = NO -i (kernel default = num_online_cpus queues, like
                                        # fig-7d multi-queue). Set a number to force -i N.
EXPECT="${EXPECT:-4}"                   # expected namespace HEAD count (4 either layout)

# Args (survive the sudo re-exec): [--expect N] then NQNs. Fall back to the
# legacy 4-subsystem default when none are given.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --expect) EXPECT="$2"; shift 2 ;;
        --expect=*) EXPECT="${1#*=}"; shift ;;
        --) shift; break ;;
        -*) echo "unknown arg: $1"; exit 1 ;;
        *) break ;;
    esac
done
if [[ $# -gt 0 ]]; then
    NQNS=("$@")
else
    NQNS=(nvmet-ens17np0-nvme6n1 nvmet-ens17np0-nvme7n1 nvmet-ens17np0-nvme8n1 nvmet-ens17np0-nvme9n1)
fi

# sanity: the data NIC must carry DATA_IP (run setup.sh / stream5-net.sh first)
NIC="$(ip -o -4 addr show | awk -v ip="$DATA_IP" '$0 ~ ip"/"{print $2; exit}')"
[[ -n "$NIC" ]] || { echo "ERROR: no NIC has $DATA_IP (run ./stream5-net.sh first)"; exit 1; }
echo "[connect] data NIC=$NIC ($DATA_IP) -> target $TADDR:$TSVC, ${#NQNS[@]} subsystems, -i='${NUM_IO_QUEUE:-default(num_online_cpus)}'"

modprobe nvme_tcp 2>/dev/null || true

connect_one() {  # nqn
    local nqn="$1" i
    nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
    for i in 1 2 3 4 5; do
        nvme connect -t tcp -n "$nqn" -a "$TADDR" -s "$TSVC" \
             --disable-sqflow ${NUM_IO_QUEUE:+-i "$NUM_IO_QUEUE"} && return 0
        echo "  retry $i/5: $nqn @ $TADDR"
        nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
        sleep 2
    done
    echo "  WARN: connect failed $nqn @ $TADDR (after retries)"; return 1
}

# Count unique head devices behind tcp controllers (nvme_core.multipath=Y: the
# path is nvmeXcYn1, the usable head is nvmeXn1).
count_heads() {
    local c ns head n=0; declare -A seen
    for c in /sys/class/nvme/nvme*; do
        [[ -r "$c/transport" ]] || continue
        [[ "$(cat "$c/transport" 2>/dev/null)" == tcp ]] || continue
        for ns in "$c"/nvme*n*; do
            [[ -e "$ns" ]] || continue
            head="$(basename "$ns" | sed -E 's/c[0-9]+n/n/')"
            [[ -b "/dev/$head" ]] || continue
            [[ -n "${seen[$head]:-}" ]] && continue
            seen[$head]=1; n=$((n+1))
        done
    done
    echo "$n"
}

for nqn in "${NQNS[@]}"; do connect_one "$nqn"; done
sleep 2

ndev="$(count_heads)"
echo "[connect] $ndev NVMe/TCP namespace(s) present"
[[ "$ndev" -ge "$EXPECT" ]] || echo "  WARN: expected $EXPECT, got $ndev"
[[ "$ndev" -gt 0 ]] || { echo "ERROR: no NVMe/TCP devices appeared"; exit 1; }

echo "[connect] target devices:"
for nqn in "${NQNS[@]}"; do
    for b in /sys/block/nvme*n*; do
        [[ -r "$b/device/subsysnqn" ]] || continue
        bn="$(basename "$b")"; [[ "$bn" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        [[ "$(cat "$b/device/subsysnqn")" == "$nqn" ]] && echo "  /dev/$bn  <- $nqn"
    done
done
