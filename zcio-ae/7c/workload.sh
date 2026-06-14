#!/bin/bash
# workload.sh (fig-7c) — single-core test: 4 devices over ONE NIC (ens17np0 /
# 10.3.95.10). Simpler than the 2-NIC setup since the bottleneck is the 1 initiator
# core, not the device/NIC count.
#
# Connects the 4 NVMe/TCP subsystems on that NIC, runs a read block-size sweep
# across all 4 namespaces at once, and reports the STEADY-STATE RX throughput on
# that NIC (the first 5s window whose CoV drops below STEADY_THRESH%).
#
# fio parameters live in per-block-size files workload-<bs>.fio (e.g.
# workload-4k.fio), each a [global]-only file you edit to tune that block size;
# this script appends one [devN] section per device. Sweeps bs over BS_LIST.
#
# Self-execs via sudo -n.   Usage:  ./workload.sh <out_dir>
set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
cd "$(dirname "$SCRIPT_PATH")"

# ===== both NIC pairs + their 8 subsystems (from nvmet-9100.sh) =======
TSVC="${TSVC:-4420}"
TADDR_95="10.3.95.10"; TADDR_96="10.3.96.10"
NQNS_95=(nvmet-ens17np0-nvme6n1 nvmet-ens17np0-nvme7n1 nvmet-ens17np0-nvme8n1 nvmet-ens17np0-nvme9n1)
NQNS_96=()   # single-NIC simplification: only ens17np0 (10.3.95.10), 4 devices (single-core test)

# Per-(config,bs) fio param files: workload-<config>-<bs>.fio (edit each to tune).
BS_LIST=(${BS_LIST:-4k 16k 32k 64k 128k 256k 512k})
# Steady-state measurement (fio runtime in workload.fio must exceed MAX_SAMPLE_SECS):
WARMUP_SECS="${WARMUP_SECS:-10}"
STEADY_WINDOW="${STEADY_WINDOW:-5}"
STEADY_THRESH="${STEADY_THRESH:-5}"
MAX_SAMPLE_SECS="${MAX_SAMPLE_SECS:-20}"

OUT="${1:-results-run}"
CONFIG="${2:?usage: workload.sh <out_dir> <config>}"
# ======================================================================

mkdir -p "$OUT"
SUMMARY="$OUT/summary.csv"

# Resolve which NIC carries each data IP (matches stream5-net.sh assignment).
NIC_95="$(ip -o -4 addr show | awk '/10\.3\.95\.5\//{print $2; exit}')"
[[ -n "$NIC_95" ]] || { echo "ERROR: data NIC not configured (run stream5-net.sh first)"; exit 1; }
RX95="/sys/class/net/$NIC_95/statistics/rx_bytes"
echo "[workload] data NIC: .95=$NIC_95 (single-NIC, 4 devices)"

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
        nvme connect -t tcp -n "$nqn" -a "$addr" -s "$TSVC" --disable-sqflow && return 0
        echo "  retry $i/5: $nqn @ $addr"
        nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
        sleep 2
    done
    echo "  WARN: connect failed $nqn @ $addr (after retries)"
    return 1
}

echo "[workload] connecting 8 subsystems ..."
modprobe nvme_tcp 2>/dev/null || true
for nqn in "${NQNS_95[@]}"; do connect_one "$nqn" "$TADDR_95"; done
for nqn in "${NQNS_96[@]}"; do connect_one "$nqn" "$TADDR_96"; done

DEVS=()
for nqn in "${NQNS_95[@]}" "${NQNS_96[@]}"; do
    dev=""; for _ in $(seq 1 20); do dev="$(find_dev "$nqn")" && break; sleep 0.5; done
    [[ -n "$dev" ]] && DEVS+=("$dev") || echo "  WARN: no device for $nqn"
done
[[ ${#DEVS[@]} -gt 0 ]] || { echo "ERROR: no target devices appeared"; exit 1; }
echo "[workload] ${#DEVS[@]} devices: ${DEVS[*]}"
echo

# Build a job file from workload.fio ([global] only) + bs + one [devN] per device.
build_job() {  # bs file  -> concatenate workload-<config>-<bs>.fio + one [devN] per device
    local bs="$1" f="$2" i=0 jobfile="workload-${CONFIG}-${bs}.fio"
    [[ -f "$jobfile" ]] || { echo "  ERROR: fio param file '$jobfile' not found"; return 1; }
    cat "$jobfile" > "$f"
    for d in "${DEVS[@]}"; do
        printf '\n[dev%d]\nfilename=%s\n' "$i" "$d" >> "$f"
        i=$((i+1))
    done
}

kill_fio() {  # pid
    kill -TERM "$1" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
    pkill -9 -x fio 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

echo "bs,net_steady_GBps,steady_CoV_pct,fio_read_MiBps,fio_read_kIOPS,fio_clat_us_mean" > "$SUMMARY"

for bs in "${BS_LIST[@]}"; do
    echo "================ bs=$bs  (${#DEVS[@]} devs) ================"
    job="$(mktemp)"; build_job "$bs" "$job" || { rm -f "$job"; continue; }

    fio "$job" --output-format=json --output="$OUT/$bs.json" 2>"$OUT/$bs.err" &
    fpid=$!

    # Per-second summed-RX (both NICs) sampling with steady-state detection.
    prev_rx=$(cat "$RX95"); prev_t=$(date +%s.%N)
    tps=(); steady=0; early=0
    for _ in $(seq 1 "$MAX_SAMPLE_SECS"); do
        kill -0 "$fpid" 2>/dev/null || { early=1; break; }
        sleep 1
        cur_rx=$(cat "$RX95"); cur_t=$(date +%s.%N)
        g=$(awk -v a="$prev_rx" -v b="$cur_rx" -v t0="$prev_t" -v t1="$cur_t" \
              'BEGIN{dt=t1-t0; printf "%.4f", (dt>0)?(b-a)/dt/1e9:0}')
        tps+=("$g"); prev_rx="$cur_rx"; prev_t="$cur_t"
        if (( ${#tps[@]} >= WARMUP_SECS + STEADY_WINDOW )); then
            win=("${tps[@]: -STEADY_WINDOW}")
            cov=$(printf '%s\n' "${win[@]}" | awk \
              '{s+=$1; ss+=$1*$1; n++} END{m=s/n; v=ss/n-m*m; sd=(v>0)?sqrt(v):0;
                printf "%.3f", (m>0)?100*sd/m:999}')
            awk -v c="$cov" -v th="$STEADY_THRESH" 'BEGIN{exit !(c<th)}' && { steady=1; break; }
        fi
    done

    # fio may finish (its runtime) before/while we sample. That's fine as long as
    # we collected enough samples — use them. Only skip if too few (fio failed).
    if [[ "$early" -eq 1 ]]; then wait "$fpid" 2>/dev/null || true; else kill_fio "$fpid"; fi
    rm -f "$job"
    if (( ${#tps[@]} < WARMUP_SECS + STEADY_WINDOW )); then
        echo "  fio produced too few samples (${#tps[@]}) — see $bs.err:"; sed 's/^/    /' "$OUT/$bs.err"; continue
    fi

    win=("${tps[@]: -STEADY_WINDOW}")
    read -r steady_gbps cov_pct <<<"$(printf '%s\n' "${win[@]}" | awk \
        '{s+=$1; ss+=$1*$1; n++} END{m=s/n; v=ss/n-m*m; sd=(v>0)?sqrt(v):0;
          printf "%.2f %.2f", m, (m>0)?100*sd/m:0}')"
    [[ "$steady" -eq 1 ]] && tag="steady" || tag="NOT-converged(capped ${MAX_SAMPLE_SECS}s)"

    python3 - "$OUT/$bs.json" "$bs" "$steady_gbps" "$cov_pct" "$tag" "$SUMMARY" <<'PY'
import json, sys
jf, bs, steady, cov, tag, summ = sys.argv[1:]
try:
    raw = open(jf).read()
    jobs = json.loads(raw[raw.index('{'):])['jobs']
    mbps = kiops = 0.0; clats = []
    for jb in jobs:
        rd = jb['read']
        mbps  += rd['bw'] / 1024.0
        kiops += rd['iops'] / 1000.0
        c = rd.get('clat_ns', rd.get('lat_ns', {})).get('mean', 0)
        if c: clats.append(c)
    clat = (sum(clats)/len(clats)/1000.0) if clats else 0.0
except Exception:
    mbps = kiops = clat = 0.0
print("  net RX %s(both NICs): %s GB/s  (CoV %s%%)   (fio %.0f MiB/s, %.1f kIOPS, clat %.1f us)"
      % (tag, steady, cov, mbps, kiops, clat))
open(summ,'a').write(f"{bs},{steady},{cov},{mbps:.1f},{kiops:.1f},{clat:.1f}\n")
PY
done

echo
echo "================ SUMMARY ($OUT) ================"
column -t -s, "$SUMMARY"
