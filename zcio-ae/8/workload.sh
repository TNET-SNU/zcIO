#!/bin/bash
# workload.sh — the constant test: 4 devices over ONE NIC pair.
#
# Connects the 4 NVMe/TCP subsystems that live on ONE target NIC, runs a read
# block-size sweep across all 4 namespaces at once, and reports the STEADY-STATE
# RX throughput on that single initiator NIC (the first 5s
# window whose CoV drops below STEADY_THRESH%).
#
# Default NIC + its 4 subsystems (edit below to use the other NIC's 4):
#   stream5 ens2np0 (10.3.95.5)  <->  rapids0 ens17np0 (10.3.95.10)
#   nvmet-ens17np0-nvme{6,7,8,9}n1
#
# Self-execs via sudo -n.   Usage:  ./workload.sh <out_dir>
set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
cd "$(dirname "$SCRIPT_PATH")"

# ===== the single NIC + its 4 subsystems under test ===================
TADDR="${TADDR:-10.3.95.10}"                 # target NIC IP
DATA_IP="${DATA_IP:-10.3.95.5}"              # initiator IP on the matching NIC
NQNS=(${NQNS:-nvmet-ens17np0-nvme6n1 nvmet-ens17np0-nvme7n1 nvmet-ens17np0-nvme8n1 nvmet-ens17np0-nvme9n1})
TSVC="${TSVC:-4420}"

BS_LIST=(${BS_LIST:-4k 16k 32k 64k 128k 256k 512k})
JOBS_PER_DEV="${JOBS_PER_DEV:-4}"      # total fio jobs = JOBS_PER_DEV x 4
IODEPTH="${IODEPTH:-128}"
# Steady-state measurement: the first STEADY_WINDOW-second
# window whose CoV (stddev/mean) drops below STEADY_THRESH percent.
WARMUP_SECS="${WARMUP_SECS:-10}"
STEADY_WINDOW="${STEADY_WINDOW:-5}"
STEADY_THRESH="${STEADY_THRESH:-5}"
MAX_SAMPLE_SECS="${MAX_SAMPLE_SECS:-30}"
FIO_RUNTIME="${FIO_RUNTIME:-40}"

OUT="${1:-results-run}"
# ======================================================================

mkdir -p "$OUT"
SUMMARY="$OUT/summary.csv"

NIC="$(ip -o -4 addr show | awk -v ip="$DATA_IP" '$0 ~ ip"/"{print $2; exit}')"
[[ -n "$NIC" ]] || { echo "ERROR: no NIC has $DATA_IP (run stream5-net.sh first)"; exit 1; }
RXF="/sys/class/net/$NIC/statistics/rx_bytes"
echo "[workload] NIC=$NIC ($DATA_IP)  target=$TADDR  ${#NQNS[@]} subsystems"

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
    echo "[workload] disconnecting ${#NQNS[@]} subsystems ..."
    local nqn; for nqn in "${NQNS[@]}"; do nvme disconnect -n "$nqn" >/dev/null 2>&1 || true; done
}
trap disconnect_all EXIT

echo "[workload] connecting ${#NQNS[@]} subsystems @ $TADDR:$TSVC ..."
modprobe nvme_tcp 2>/dev/null || true
for nqn in "${NQNS[@]}"; do
    nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
    nvme connect -t tcp -n "$nqn" -a "$TADDR" -s "$TSVC" --disable-sqflow \
        || echo "  WARN: connect failed $nqn"
done

DEVS=()
for nqn in "${NQNS[@]}"; do
    dev=""; for _ in $(seq 1 20); do dev="$(find_dev "$nqn")" && break; sleep 0.5; done
    [[ -n "$dev" ]] && DEVS+=("$dev") || echo "  WARN: no device for $nqn"
done
[[ ${#DEVS[@]} -gt 0 ]] || { echo "ERROR: no target devices appeared"; exit 1; }
echo "[workload] ${#DEVS[@]} devices: ${DEVS[*]}"
echo

build_job() {  # bs file  -> concatenate workload-<bs>.fio + one [devN] per device
    local bs="$1" f="$2" i=0 jobfile="workload-${bs}.fio"
    [[ -f "$jobfile" ]] || { echo "  ERROR: fio param file '$jobfile' not found"; return 1; }
    cat "$jobfile" > "$f"
    for d in "${DEVS[@]}"; do printf '\n[dev%d]\nfilename=%s\n' "$i" "$d" >> "$f"; i=$((i+1)); done
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

    prev_rx=$(cat "$RXF"); prev_t=$(date +%s.%N)
    tps=(); steady=0; early=0
    for _ in $(seq 1 "$MAX_SAMPLE_SECS"); do
        kill -0 "$fpid" 2>/dev/null || { early=1; break; }
        sleep 1
        cur_rx=$(cat "$RXF"); cur_t=$(date +%s.%N)
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

    if [[ "$early" -eq 1 ]]; then
        wait "$fpid"; echo "  fio exited early:"; sed 's/^/    /' "$OUT/$bs.err"
        rm -f "$job"; continue
    fi
    kill_fio "$fpid"; rm -f "$job"

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
print("  net RX %s: %s GB/s  (CoV %s%%)   (fio %.0f MiB/s, %.1f kIOPS, clat %.1f us)"
      % (tag, steady, cov, mbps, kiops, clat))
open(summ,'a').write(f"{bs},{steady},{cov},{mbps:.1f},{kiops:.1f},{clat:.1f}\n")
PY
done

echo
echo "================ SUMMARY ($OUT) ================"
column -t -s, "$SUMMARY"
