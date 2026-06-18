#!/bin/bash
# connect-targets.sh (initiator, write path) — connect NVMe/TCP subsystems with
# the KERNEL initiator (used for every config; for the SPDK config the only
# difference is the target runs SPDK, the initiator is still the kernel).
#
# TWO-INITIATOR split: the 8 subsystems are driven by two hosts, 4 each —
#   stream5 -> the 4 @ 10.3.96.10  (GROUP=96)
#   stream6 -> the 4 @ 10.3.95.10  (GROUP=95)
# so each host connects only its own group. GROUP=both keeps the old single-host
# behavior (all 8).
#
#   Usage:  ./connect-targets.sh [kernel|spdk] [95|96|both]   (default: kernel both)
#     or set GROUP=95|96|both in the env.
#
#   kernel : connect the explicit nvmet NQNs for the group.
#   spdk   : poll discovery then `nvme connect-all` for the group's target IP
#            (SPDK NQNs are named differently, so discover them).
#
# Self-execs via sudo -n.
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
cd "$(dirname "$SCRIPT_PATH")"

MODE="${1:-kernel}"
GROUP="${2:-${GROUP:-both}}"
TSVC="${TSVC:-4420}"
TADDR_95="10.3.95.10"; TADDR_96="10.3.96.10"
NQNS_95=(nvmet-ens17np0-nvme6n1 nvmet-ens17np0-nvme7n1 nvmet-ens17np0-nvme8n1 nvmet-ens17np0-nvme9n1)
NQNS_96=(nvmet-ens19np0-nvme2n1 nvmet-ens19np0-nvme3n1 nvmet-ens19np0-nvme4n1 nvmet-ens19np0-nvme5n1)
NUM_IO_QUEUE=8  #8 -spdk

case "$GROUP" in
  95)   EXPECT_DEFAULT=4 ;;
  96)   EXPECT_DEFAULT=4 ;;
  both) EXPECT_DEFAULT=8 ;;
  *)    echo "ERROR: unknown GROUP '$GROUP' (95|96|both)"; exit 1 ;;
esac
EXPECT="${EXPECT:-$EXPECT_DEFAULT}"

modprobe nvme_tcp 2>/dev/null || true
nvme disconnect-all >/dev/null 2>&1 || true   # clear stale connections (prior run / target reboot)

connect_one() {  # nqn addr
    local nqn="$1" addr="$2" i
    for i in 1 2 3 4 5; do
        nvme connect -t tcp -n "$nqn" -a "$addr" -s "$TSVC" --disable-sqflow -i ${NUM_IO_QUEUE} && return 0
        echo "  retry $i/5: $nqn @ $addr"
        nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
        sleep 2
    done
    echo "  WARN: connect failed $nqn @ $addr (after retries)"; return 1
}

# SPDK: connect ONLY the subsystems advertised AT this group's IP. The SPDK
# discovery log lists ALL subsystems with their own traddr (both .95.10 and
# .96.10), so a blind `nvme connect-all -a <ip>` would connect the other group's
# subsystems too (stream5 has both NICs up -> it would grab all 8). Filter the
# discovery log by traddr == this ip and connect those NQNs explicitly.
connect_group_ip() {  # addr  — SPDK: discover, filter by traddr, connect this group only
    local addr="$1" i nqn nqns
    for i in $(seq 1 40); do
        nvme discover -t tcp -a "$addr" -s "$TSVC" >/dev/null 2>&1 && break
        sleep 1
    done
    nqns="$(nvme discover -t tcp -a "$addr" -s "$TSVC" -o json 2>/dev/null | python3 -c '
import sys, json
ip = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in d.get("records", []):
    if str(r.get("traddr","")).strip() == ip and str(r.get("trtype","")).lower() == "tcp":
        print(str(r.get("subnqn","")).strip())
' "$addr")"
    [[ -n "$nqns" ]] || { echo "  WARN: no subsystems advertised at $addr yet"; return 1; }
    for nqn in $nqns; do [[ -n "$nqn" ]] && connect_one "$nqn" "$addr"; done
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

# build the list of (nqn,addr) for the selected group
declare -a SEL_NQN=() SEL_ADDR=() SEL_IPS=()
if [[ "$GROUP" == 95 || "$GROUP" == both ]]; then
    for nqn in "${NQNS_95[@]}"; do SEL_NQN+=("$nqn"); SEL_ADDR+=("$TADDR_95"); done
    SEL_IPS+=("$TADDR_95")
fi
if [[ "$GROUP" == 96 || "$GROUP" == both ]]; then
    for nqn in "${NQNS_96[@]}"; do SEL_NQN+=("$nqn"); SEL_ADDR+=("$TADDR_96"); done
    SEL_IPS+=("$TADDR_96")
fi

case "$MODE" in
  kernel)
    echo "[connect] kernel nvmet NQNs (group=$GROUP, expect=$EXPECT) ..."
    for i in "${!SEL_NQN[@]}"; do connect_one "${SEL_NQN[$i]}" "${SEL_ADDR[$i]}"; done
    sleep 2
    ;;
  spdk)
    # The SPDK target needs a few seconds to bring up listeners and register all
    # subsystems; discovery can race and report a subset. Retry the (traddr-filtered)
    # per-group connect until all EXPECT show up.
    echo "[connect] SPDK target via discovery (group=$GROUP, traddr-filtered), waiting for $EXPECT ..."
    for attempt in $(seq 1 20); do
        for ip in "${SEL_IPS[@]}"; do connect_group_ip "$ip"; done
        sleep 2
        n="$(count_heads)"
        [[ "$n" -ge "$EXPECT" ]] && break
        echo "  have $n/$EXPECT — retrying connect ($attempt) ..."
        sleep 3
    done
    ;;
  *) echo "ERROR: unknown mode '$MODE' (kernel|spdk)"; exit 1 ;;
esac

ndev="$(count_heads)"
echo "[connect] $ndev NVMe/TCP namespaces present (group=$GROUP)"
[[ "$ndev" -ge "$EXPECT" ]] || echo "  WARN: expected $EXPECT, got $ndev"
[[ "$ndev" -gt 0 ]] || { echo "ERROR: no NVMe/TCP devices appeared"; exit 1; }
