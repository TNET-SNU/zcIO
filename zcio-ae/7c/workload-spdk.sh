#!/bin/bash
# workload-spdk.sh — SPDK baseline for fig-7c. Uses SPDK's userspace NVMe/TCP
# initiator (spdk_bdev fio plugin) instead of the kernel nvme-tcp stack. SPDK's
# TCP transport rides the kernel posix sockets, so RX still lands on ens2np0/
# ens3np0 and the same steady summed-RX measurement applies.
#
# No kernel `nvme connect` here — SPDK attaches the 8 controllers from
# spdk_nvme.json when fio starts. Block size is swept via --bs.
#
# Self-execs via sudo -n (SPDK needs root: hugepages/vfio).
#   Usage:  ./workload-spdk.sh <out_dir>
set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
cd "$(dirname "$SCRIPT_PATH")"

# ----- SPDK locations (now under junghan's home) ----------------------
SPDK_DIR="${SPDK_DIR:-/opt/spdk}"
FIO_BIN="${FIO_BIN:-/opt/fio/fio}"
SPDK_PLUGIN="${SPDK_PLUGIN:-$SPDK_DIR/build/fio/spdk_bdev}"
SETUP="${SETUP:-$SPDK_DIR/scripts/setup.sh}"
JSON="$(pwd)/spdk_nvme.json"
# per-bs fio file: workload-spdk-<bs>.fio (bs is set inside each file)

BS_LIST=(${BS_LIST:-4k 16k 32k 64k 128k 256k 512k})
WARMUP_SECS="${WARMUP_SECS:-10}"
STEADY_WINDOW="${STEADY_WINDOW:-5}"
STEADY_THRESH="${STEADY_THRESH:-5}"
MAX_SAMPLE_SECS="${MAX_SAMPLE_SECS:-20}"

OUT="${1:-results-spdk}"

for f in "$FIO_BIN" "$SPDK_PLUGIN" "$SETUP" "$JSON"; do
    [[ -e "$f" ]] || { echo "ERROR: missing $f"; exit 1; }
done
mkdir -p "$OUT"
SUMMARY="$OUT/summary.csv"

NIC_95="$(ip -o -4 addr show | awk '/10\.3\.95\.5\//{print $2; exit}')"
[[ -n "$NIC_95" ]] || { echo "ERROR: data NIC not configured (run stream5-net.sh first)"; exit 1; }
RX95="/sys/class/net/$NIC_95/statistics/rx_bytes"
echo "[spdk] NIC: .95=$NIC_95 (single-NIC, 4 devices)  json=$JSON"

# Make sure the kernel isn't holding the subsystems (SPDK attaches them itself).
nvme disconnect-all >/dev/null 2>&1 || true

# ----- SPDK prep: hugepages (idempotent) ------------------------------
echo "[spdk] $SETUP"
"$SETUP" || { echo "ERROR: SPDK setup.sh failed"; exit 1; }

kill_fio() {
    kill -TERM "$1" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
    pkill -9 -x fio 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

echo "bs,net_steady_GBps" > "$SUMMARY"

for bs in "${BS_LIST[@]}"; do
    echo "================ bs=$bs (SPDK) ================"
    tmpl="workload-spdk-${bs}.fio"
    [[ -f "$tmpl" ]] || { echo "  WARN: $tmpl not found — skipping bs=$bs"; continue; }
    job="$(mktemp --suffix=.fio)"
    sed "s#__JSON__#$JSON#" "$tmpl" > "$job"

    LD_PRELOAD="$SPDK_PLUGIN" "$FIO_BIN" "$job" \
        >/dev/null 2>"$OUT/$bs.err" &
    fpid=$!

    prev_rx=$(cat "$RX95"); prev_t=$(date +%s.%N)
    tps=(); steady=0; early=0
    for _ in $(seq 1 "$MAX_SAMPLE_SECS"); do
        kill -0 "$fpid" 2>/dev/null || { early=1; break; }
        sleep 1
        cur_rx=$(cat "$RX95"); cur_t=$(date +%s.%N)
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
        echo "  SPDK fio produced too few samples (${#tps[@]}) — see $bs.err:"; sed 's/^/    /' "$OUT/$bs.err"; continue
    fi

    win=("${tps[@]: -STEADY_WINDOW}")
    read -r steady_gbps cov_pct <<<"$(printf '%s\n' "${win[@]}" | awk '{s+=$1;ss+=$1*$1;nn++} END{m=s/nn;v=ss/nn-m*m;sd=(v>0)?sqrt(v):0;printf "%.2f %.2f",m,(m>0)?100*sd/m:0}')"
    [[ "$steady" -eq 1 ]] && tag="steady" || tag="NOT-converged(${MAX_SAMPLE_SECS}s)"
    echo "  bs=$bs  net RX $tag: $steady_gbps GB/s  (CoV $cov_pct%)"
    echo "$bs,$steady_gbps" >> "$SUMMARY"
done

echo
echo "================ SUMMARY ($OUT) ================"
column -t -s, "$SUMMARY"
