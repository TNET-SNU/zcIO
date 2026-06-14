#!/bin/bash
# connect-targets.sh (stream5, write path) — connect the 8 NVMe/TCP subsystems
# with the KERNEL initiator (used for every config; for the SPDK config the only
# difference is the target runs SPDK, the initiator is still the kernel).
#
#   Usage:  ./connect-targets.sh [kernel|spdk]   (default: kernel)
#
#   kernel : connect the 8 explicit nvmet NQNs (4 @ .95.10, 4 @ .96.10).
#   spdk   : poll discovery then `nvme connect-all` per target IP (SPDK NQNs are
#            named differently, so discover them instead of hardcoding).
#
# Self-execs via sudo -n.
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
cd "$(dirname "$SCRIPT_PATH")"

MODE="${1:-kernel}"
TSVC="${TSVC:-4420}"
TADDR_95="10.3.95.10"; TADDR_96="10.3.96.10"
NQNS_95=(nvmet-ens17np0-nvme6n1 nvmet-ens17np0-nvme7n1 nvmet-ens17np0-nvme8n1 nvmet-ens17np0-nvme9n1)
NQNS_96=(nvmet-ens19np0-nvme2n1 nvmet-ens19np0-nvme3n1 nvmet-ens19np0-nvme4n1 nvmet-ens19np0-nvme5n1)

modprobe nvme_tcp 2>/dev/null || true
nvme disconnect-all >/dev/null 2>&1 || true   # clear stale connections (prior run / target reboot)

connect_one() {  # nqn addr
    local nqn="$1" addr="$2" i
    for i in 1 2 3 4 5; do
        nvme connect -t tcp -n "$nqn" -a "$addr" -s "$TSVC" --disable-sqflow && return 0
        echo "  retry $i/5: $nqn @ $addr"
        nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
        sleep 2
    done
    echo "  WARN: connect failed $nqn @ $addr (after retries)"; return 1
}

connect_all_ip() {  # addr  — SPDK: wait for discovery, then connect every subsystem
    local addr="$1" i
    for i in $(seq 1 40); do
        nvme discover -t tcp -a "$addr" -s "$TSVC" >/dev/null 2>&1 && break
        sleep 1
    done
    nvme connect-all -t tcp -a "$addr" -s "$TSVC" 2>/dev/null || true
}

# Count unique head devices behind tcp controllers (nvme_core.multipath=Y: the path
# is nvmeXcYn1, the usable head is nvmeXn1).
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

EXPECT="${EXPECT:-8}"
case "$MODE" in
  kernel)
    echo "[connect] kernel nvmet NQNs ..."
    for nqn in "${NQNS_95[@]}"; do connect_one "$nqn" "$TADDR_95"; done
    for nqn in "${NQNS_96[@]}"; do connect_one "$nqn" "$TADDR_96"; done
    sleep 2
    ;;
  spdk)
    # The SPDK target needs a few seconds to bring up both listeners and register
    # all subsystems; a single connect-all can race and grab only a subset (the
    # cause of "only 5/8 connected"). Retry connect-all until all EXPECT show up.
    echo "[connect] SPDK target via discovery (connect-all), waiting for $EXPECT ..."
    for attempt in $(seq 1 20); do
        connect_all_ip "$TADDR_95"
        connect_all_ip "$TADDR_96"
        sleep 2
        n="$(count_heads)"
        [[ "$n" -ge "$EXPECT" ]] && break
        echo "  have $n/$EXPECT — retrying connect-all ($attempt) ..."
        sleep 3
    done
    ;;
  *) echo "ERROR: unknown mode '$MODE' (kernel|spdk)"; exit 1 ;;
esac

ndev="$(count_heads)"
echo "[connect] $ndev NVMe/TCP namespaces present"
[[ "$ndev" -ge "$EXPECT" ]] || echo "  WARN: expected $EXPECT, got $ndev"
[[ "$ndev" -gt 0 ]] || { echo "ERROR: no NVMe/TCP devices appeared"; exit 1; }
