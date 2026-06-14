#!/bin/bash
# workload-spdk.sh (fig-7d) — SPDK baseline, fixed 256k, swept over stream5 core
# count. SPDK uses its userspace NVMe/TCP initiator (kernel posix sockets, so RX
# still lands on the NICs and the same steady measurement applies).
#
# SPDK attaches the 8 controllers per fio run (from spdk_nvme.json) and is NOT
# affected by the kernel multi-queue-connect bug, so we just cpu-limit to N and
# run SPDK fio at each core count.
#
# Self-execs via sudo -n.   Usage:  ./workload-spdk.sh <out_dir> <cores-list>
set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
cd "$(dirname "$SCRIPT_PATH")"

SPDK_DIR="${SPDK_DIR:-/opt/spdk}"
FIO_BIN="${FIO_BIN:-/opt/fio/fio}"
SPDK_PLUGIN="${SPDK_PLUGIN:-$SPDK_DIR/build/fio/spdk_bdev}"
SETUP="${SETUP:-$SPDK_DIR/scripts/setup.sh}"
JSON="$(pwd)/spdk_nvme.json"
# per-core fio file: workload-spdk-<N>.fio (bs is set inside each file)

WARMUP_SECS="${WARMUP_SECS:-10}"
STEADY_WINDOW="${STEADY_WINDOW:-5}"
STEADY_THRESH="${STEADY_THRESH:-5}"
MAX_SAMPLE_SECS="${MAX_SAMPLE_SECS:-20}"

OUT="${1:?usage: workload-spdk.sh <out_dir> <cores-list>}"
CORES=(${2:?usage: workload-spdk.sh <out_dir> <cores-list>})

for f in "$FIO_BIN" "$SPDK_PLUGIN" "$SETUP" "$JSON"; do
    [[ -e "$f" ]] || { echo "ERROR: missing $f"; exit 1; }
done
mkdir -p "$OUT"
SUMMARY="$OUT/summary.csv"

NIC_95="$(ip -o -4 addr show | awk '/10\.3\.95\.5\//{print $2; exit}')"
NIC_96="$(ip -o -4 addr show | awk '/10\.3\.96\.5\//{print $2; exit}')"
[[ -n "$NIC_95" && -n "$NIC_96" ]] || { echo "ERROR: data NICs not configured (run stream5-net.sh first)"; exit 1; }
RX95="/sys/class/net/$NIC_95/statistics/rx_bytes"
RX96="/sys/class/net/$NIC_96/statistics/rx_bytes"
echo "[spdk] NICs: .95=$NIC_95 .96=$NIC_96  core sweep: ${CORES[*]}"

nvme disconnect-all >/dev/null 2>&1 || true     # SPDK attaches the subsystems itself
echo "[spdk] $SETUP"
"$SETUP" || { echo "ERROR: SPDK setup.sh failed"; exit 1; }

kill_fio() {
    kill -TERM "$1" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
    pkill -9 -x fio 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

echo "cores,net_steady_GBps" > "$SUMMARY"

for n in "${CORES[@]}"; do
    echo "================ cores=$n (SPDK) ================"
    ./cpu-limit.sh "$n" || echo "  WARN: cpu-limit $n failed"
    ./cpu-governor.sh performance >/dev/null 2>&1 || true
    ./set-irq-affinity.sh >/dev/null 2>&1 || true
    sleep 1

    tmpl="workload-spdk-${n}.fio"
    [[ -f "$tmpl" ]] || { echo "  WARN: $tmpl not found — skipping cores=$n"; continue; }
    job="$(mktemp --suffix=.fio)"
    sed "s#__JSON__#$JSON#" "$tmpl" > "$job"
    LD_PRELOAD="$SPDK_PLUGIN" "$FIO_BIN" "$job" >/dev/null 2>"$OUT/cores-$n.err" &
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
        echo "  SPDK fio produced too few samples (${#tps[@]}) — see cores-$n.err:"; sed 's/^/    /' "$OUT/cores-$n.err"; continue
    fi

    win=("${tps[@]: -STEADY_WINDOW}")
    read -r steady_gbps cov_pct <<<"$(printf '%s\n' "${win[@]}" | awk '{s+=$1;ss+=$1*$1;nn++} END{m=s/nn;v=ss/nn-m*m;sd=(v>0)?sqrt(v):0;printf "%.2f %.2f",m,(m>0)?100*sd/m:0}')"
    [[ "$steady" -eq 1 ]] && tag="steady" || tag="NOT-converged(${MAX_SAMPLE_SECS}s)"
    echo "  cores=$n  net RX $tag: $steady_gbps GB/s  (CoV $cov_pct%)"
    echo "$n,$steady_gbps" >> "$SUMMARY"
done

echo
echo "================ SUMMARY ($OUT) ================"
column -t -s, "$SUMMARY"
