#!/bin/bash
# workload.sh (fig-7d) — connect the 8 NVMe/TCP subsystems ONCE at full cores
# (multi-queue connect needs all CPUs online on this kernel — connecting with
# CPUs offlined fails: "failed to connect queue: N ret=-18"), then sweep the
# stream5 core count DOWN, running 256k random read + steady measurement at each.
# One row per core count; disconnect once at the end.
#
#   Usage:  ./workload.sh <out_dir> <cores-list> [jobfile]
#   e.g.    ./workload.sh results-linux linux "15 12 8 4 2 1"
#
# The core list MUST be descending (we only ever offline more cores after the
# full-core connect; onlining cores mid-run would re-trigger the connect path).
set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
cd "$(dirname "$SCRIPT_PATH")"

TSVC="${TSVC:-4420}"
TADDR_95="10.3.95.10"; TADDR_96="10.3.96.10"
NQNS_95=(nvmet-ens17np0-nvme6n1 nvmet-ens17np0-nvme7n1 nvmet-ens17np0-nvme8n1 nvmet-ens17np0-nvme9n1)
NQNS_96=(nvmet-ens19np0-nvme2n1 nvmet-ens19np0-nvme3n1 nvmet-ens19np0-nvme4n1 nvmet-ens19np0-nvme5n1)

WARMUP_SECS="${WARMUP_SECS:-20}"
STEADY_WINDOW="${STEADY_WINDOW:-10}"
STEADY_THRESH="${STEADY_THRESH:-15}"
MAX_SAMPLE_SECS="${MAX_SAMPLE_SECS:-50}"   # cap when it never converges (e.g. 1 core)

OUT="${1:?usage: workload.sh <out_dir> <config> <cores-list>}"
CONFIG="${2:?usage: workload.sh <out_dir> <config> <cores-list>}"
CORES=(${3:?usage: workload.sh <out_dir> <config> <cores-list>})
# per-core fio file: workload-<config>-<N>.fio  (edit each to tune that point)

mkdir -p "$OUT"
SUMMARY="$OUT/summary.csv"

NIC_95="$(ip -o -4 addr show | awk '/10\.3\.95\.5\//{print $2; exit}')"
NIC_96="$(ip -o -4 addr show | awk '/10\.3\.96\.5\//{print $2; exit}')"
[[ -n "$NIC_95" && -n "$NIC_96" ]] || { echo "ERROR: data NICs not configured (run stream5-net.sh first)"; exit 1; }
RX95="/sys/class/net/$NIC_95/statistics/rx_bytes"
RX96="/sys/class/net/$NIC_96/statistics/rx_bytes"
echo "[workload] config=$CONFIG  core sweep: ${CORES[*]}  NICs: .95=$NIC_95 .96=$NIC_96"

find_dev() {  # nqn
    local nqn="$1" b bn s c ns head
    for b in /sys/block/nvme*n*; do
        [[ -e "$b" ]] || continue
        bn="$(basename "$b")"
        [[ "$bn" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        [[ -r "$b/device/subsysnqn" ]] || continue
        [[ "$(cat "$b/device/subsysnqn")" == "$nqn" ]] && { echo "/dev/$bn"; return 0; }
    done
    for s in /sys/class/nvme/nvme*/subsysnqn; do
        [[ -r "$s" ]] || continue
        [[ "$(cat "$s")" == "$nqn" ]] || continue
        c="${s%/subsysnqn}"
        ns="$(basename "$(ls -d "$c"/nvme*n* 2>/dev/null | head -1)" 2>/dev/null)"
        [[ -n "$ns" ]] || continue
        head="$(echo "$ns" | sed -E 's/c[0-9]+n/n/')"
        [[ -b "/dev/$head" ]] && { echo "/dev/$head"; return 0; }
    done
    return 1
}

disconnect_all() {
    echo "[workload] disconnecting 8 subsystems ..."
    local nqn; for nqn in "${NQNS_95[@]}" "${NQNS_96[@]}"; do nvme disconnect -n "$nqn" >/dev/null 2>&1 || true; done
}
trap disconnect_all EXIT

connect_one() {  # nqn addr  — retry: some of the 8 occasionally time out under burst
    local nqn="$1" addr="$2" i
    for i in 1 2 3 4 5; do
        nvme connect -t tcp -n "$nqn" -a "$addr" -s "$TSVC" --disable-sqflow -i 27 && return 0
        echo "  retry $i/5: $nqn @ $addr"
        nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
        sleep 2
    done
    echo "  WARN: connect failed $nqn @ $addr (after retries)"
    return 1
}

# ----- connect ONCE at full cores -------------------------------------
echo "[workload] connecting 8 subsystems (at full cores) ..."
nvme disconnect-all >/dev/null 2>&1 || true
sleep 1
for nqn in "${NQNS_95[@]}"; do connect_one "$nqn" "$TADDR_95"; done
for nqn in "${NQNS_96[@]}"; do connect_one "$nqn" "$TADDR_96"; done
sleep 5  # let the 8 controllers settle before probing/running fio

DEVS=()
for nqn in "${NQNS_95[@]}" "${NQNS_96[@]}"; do
    dev=""; for _ in $(seq 1 20); do dev="$(find_dev "$nqn")" && break; sleep 0.5; done
    [[ -n "$dev" ]] && DEVS+=("$dev") || echo "  WARN: no device for $nqn"
done
[[ ${#DEVS[@]} -gt 0 ]] || { echo "ERROR: no target devices appeared"; exit 1; }
echo "[workload] ${#DEVS[@]} devices: ${DEVS[*]}"

# ----- ensure the TARGET (rapids0) keeps the larger RX ring ------------
# target-net-config.sh sets this, but only runs via all_in_one prep; when
# workload.sh is run directly the target ring can sit at the driver default
# (and it reverts on any mlx5 reload). Assert rx=8192 here so every run uses
# it. workload.sh runs as root, so ssh as the invoking user ($SUDO_USER).
RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
RUN_AS="${SUDO_USER:-$USER}"
for tnic in ens17np0 ens19np0; do
    if sudo -u "$RUN_AS" ssh -o ConnectTimeout=10 "$RAPIDS0" "sudo -n ethtool -G $tnic rx 8192" 2>/dev/null; then
        cur=$(sudo -u "$RUN_AS" ssh -o ConnectTimeout=10 "$RAPIDS0" "ethtool -g $tnic 2>/dev/null | awk '/Current/{f=1} f&&/RX:/{print \$2; exit}'")
        echo "[workload] rapids0 $tnic rx ring -> ${cur:-?}"
    else
        echo "[workload] WARN: could not set rapids0 $tnic rx ring (check ssh/sudo)"
    fi
done

build_job() {  # jobfile out_file
    local jf="$1" f="$2" i=0
    cat "$jf" > "$f"
    for d in "${DEVS[@]}"; do printf '\n[dev%d]\nfilename=%s\n' "$i" "$d" >> "$f"; i=$((i+1)); done
}
kill_fio() {
    kill -TERM "$1" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
    pkill -9 -x fio 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

echo "cores,net_steady_GBps,fio_read_GBps" > "$SUMMARY"

# ----- sweep core count DOWN, measuring at each ------------------------
for n in "${CORES[@]}"; do
    echo "================ cores=$n ================"
    ./cpu-limit.sh "$n" || echo "  WARN: cpu-limit $n failed"
    ./cpu-governor.sh performance >/dev/null 2>&1 || true
    #./set-irq-affinity.sh >/dev/null 2>&1 || true
    systemctl start irqbalance 2>/dev/null || true   # let irqbalance handle IRQs (no manual pin)

    sleep 1

    jf="workload-${CONFIG}-${n}.fio"
    [[ -f "$jf" ]] || { echo "  WARN: $jf not found — skipping cores=$n"; continue; }
    job="$(mktemp)"; build_job "$jf" "$job"
    # keep fio's own stdout so we can read its reported READ bw (printed on
    # SIGTERM too) and compare it against the NIC rx-counter measurement below.
    fio "$job" >"$OUT/cores-$n.fio.log" 2>"$OUT/cores-$n.err" &
    fpid=$!

    prev_rx=$(( $(cat "$RX95") + $(cat "$RX96") )); prev_t=$(date +%s.%N)
    tps=(); steady=0; early=0
    for _ in $(seq 1 "$MAX_SAMPLE_SECS"); do
        kill -0 "$fpid" 2>/dev/null || { early=1; break; }
        sleep 1
        cur_rx=$(( $(cat "$RX95") + $(cat "$RX96") )); cur_t=$(date +%s.%N)
        g=$(awk -v a="$prev_rx" -v b="$cur_rx" -v t0="$prev_t" -v t1="$cur_t" 'BEGIN{dt=t1-t0; printf "%.4f",(dt>0)?(b-a)/dt/1e9:0}')
        tps+=("$g"); prev_rx="$cur_rx"; prev_t="$cur_t"
        if (( ${#tps[@]} >= WARMUP_SECS + STEADY_WINDOW )); then
            win=("${tps[@]: -STEADY_WINDOW}")
            cov=$(printf '%s\n' "${win[@]}" | awk '{s+=$1;ss+=$1*$1;nn++} END{m=s/nn;v=ss/nn-m*m;sd=(v>0)?sqrt(v):0;printf "%.3f",(m>0)?100*sd/m:999}')
            awk -v c="$cov" -v th="$STEADY_THRESH" 'BEGIN{exit !(c<th)}' && { steady=1; break; }
        fi
    done

    if [[ "$early" -eq 1 ]]; then wait "$fpid" 2>/dev/null || true; else kill_fio "$fpid"; fi
    rm -f "$job"
    if (( ${#tps[@]} < WARMUP_SECS + STEADY_WINDOW )); then
        echo "  fio produced too few samples (${#tps[@]}) — see cores-$n.err:"; sed 's/^/    /' "$OUT/cores-$n.err"; continue
    fi

    win=("${tps[@]: -STEADY_WINDOW}")
    read -r steady_gbps cov_pct <<<"$(printf '%s\n' "${win[@]}" | awk '{s+=$1;ss+=$1*$1;nn++} END{m=s/nn;v=ss/nn-m*m;sd=(v>0)?sqrt(v):0;printf "%.2f %.2f",m,(m>0)?100*sd/m:0}')"
    # fio's own aggregate READ bw (decimal GB/s, the parenthesised SI value) —
    # whole-run avg, comparable to the NIC steady GB/s above. "n/a" if fio was
    # SIGKILLed before printing its summary.
    fio_bw_raw="$(awk -F'[()]' '/READ: bw=/{print $2; exit}' "$OUT/cores-$n.fio.log" 2>/dev/null)"
    fio_gbps="$(awk -v s="$fio_bw_raw" 'BEGIN{if(s==""){print "n/a";exit} v=s+0; if(s~/TB\/s/)m=1000;else if(s~/GB\/s/)m=1;else if(s~/MB\/s/)m=0.001;else if(s~/kB\/s/)m=0.000001;else m=1; printf "%.2f", v*m}')"
    [[ "$steady" -eq 1 ]] && tag="steady" || tag="NOT-converged(${MAX_SAMPLE_SECS}s)"
    echo "  cores=$n  net RX $tag: $steady_gbps GB/s  (CoV $cov_pct%)   |   fio READ: $fio_gbps GB/s"
    echo "$n,$steady_gbps,$fio_gbps" >> "$SUMMARY"
done

echo
echo "================ SUMMARY ($OUT) ================"
column -t -s, "$SUMMARY"
