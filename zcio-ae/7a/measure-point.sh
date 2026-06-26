#!/bin/bash
# measure-point.sh (stream5, write path) — run ONE fio random-write point across
# all connected NVMe/TCP devices and record the STEADY-STATE TX throughput
# on ens2np0 (writes flow stream5 -> rapids0, so the initiator TX
# rate is the target receive rate). The connection is established separately by
# connect-targets.sh and persists across calls, so the core-sweep driver can
# change the TARGET core count between points without reconnecting.
#
#   Usage:  ./measure-point.sh <out_dir> <label> <fiofile> [hdr_col]
#     label   : value for the first CSV column (block size for 7a, cores for 7b)
#     fiofile : [global]-only fio params; one [devN] per device is appended
#     hdr_col : name of the first CSV column when creating summary.csv (default x)
#
# Self-execs via sudo -n.
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
cd "$(dirname "$SCRIPT_PATH")"

OUT="${1:?usage: measure-point.sh <out_dir> <label> <fiofile> [hdr_col]}"
LABEL="${2:?label}"
FIOFILE="${3:?fiofile}"
HDRCOL="${4:-x}"

# Each point is preceded by a blkdiscard cache reset (see below) so the SSD starts
# fresh. Measurement: skip a WARMUP_SECS warmup, then report the first 5s window
# whose CoV drops below threshold (same as the read figures).
WARMUP_SECS="${WARMUP_SECS:-15}"
STEADY_WINDOW="${STEADY_WINDOW:-5}"
STEADY_THRESH="${STEADY_THRESH:-5}"
MAX_SAMPLE_SECS="${MAX_SAMPLE_SECS:-30}"

# Debug: dump the full per-second TX curve (ramp / DRAM plateau / write-cliff) to
# pick the window correctly. Gated by a flag FILE (env vars don't survive the sudo
# self-exec). `touch /tmp/zcio-sample-debug` to enable; rm to disable.
DEBUG_CURVE=""
if [[ -f /tmp/zcio-sample-debug ]]; then
  DEBUG_CURVE=1; WARMUP_SECS=0; STEADY_WINDOW=2; STEADY_THRESH=-1; MAX_SAMPLE_SECS=20
fi

[[ -f "$FIOFILE" ]] || { echo "  ERROR: fio param file '$FIOFILE' not found"; exit 1; }
mkdir -p "$OUT"
chown -R "${SUDO_USER:-root}" "$OUT" 2>/dev/null || true   # so all-in-one (user) can clean between runs
SUMMARY="$OUT/summary.csv"
[[ -f "$SUMMARY" ]] || echo "$HDRCOL,net_steady_GBps,steady_CoV_pct,fio_write_MiBps,fio_write_kIOPS,fio_clat_us_mean" > "$SUMMARY"

# initiator data NICs -> tx_bytes (writes are TX on stream5)
NIC_95="$(ip -o -4 addr show | awk '/10\.3\.95\.5\//{print $2; exit}')"
[[ -n "$NIC_95" ]] || { echo "ERROR: data NIC not configured (run stream5-net.sh)"; exit 1; }
TX95="/sys/class/net/$NIC_95/statistics/tx_bytes"

# discover all NVMe/TCP namespace block devices (works for kernel nvmet and SPDK;
# handles nvme_core.multipath=Y where the path is nvmeXcYn1 and the head — the
# device fio must use — is nvmeXn1, whose /sys/block entry has no device/transport).
DEVS=()
declare -A _seen
for c in /sys/class/nvme/nvme*; do
  [[ -r "$c/transport" ]] || continue
  [[ "$(cat "$c/transport" 2>/dev/null)" == tcp ]] || continue
  for ns in "$c"/nvme*n*; do
    [[ -e "$ns" ]] || continue
    head="$(basename "$ns" | sed -E 's/c[0-9]+n/n/')"   # nvme0c0n1 -> nvme0n1
    [[ -b "/dev/$head" ]] || continue
    [[ -n "${_seen[$head]:-}" ]] && continue
    _seen[$head]=1; DEVS+=("/dev/$head")
  done
done
[[ ${#DEVS[@]} -gt 0 ]] || { echo "ERROR: no NVMe/TCP devices (connect first)"; exit 1; }
echo "[measure] label=$LABEL  ${#DEVS[@]} devs: ${DEVS[*]}  NIC: .95=$NIC_95 (single-NIC, 4 devices)"

# Reset the SSD write cache BEFORE each point so cumulative writes don't fill the
# SLC/DRAM cache and push later (large-bs) points into the SSD write cliff (which
# would hide the network/CPU bottleneck the figure is about). blkdiscard issues
# NVMe deallocate over the fabric -> the target frees the whole namespace on the
# physical SSD (works for kernel nvmet AND SPDK), resetting the cache budget; then
# idle so the drive drains SLC->TLC and GC quiesces. Tune via IDLE_SECS.
IDLE_SECS="${IDLE_SECS:-12}"
echo "[measure] reset SSD cache: blkdiscard ${#DEVS[@]} devs (parallel) + ${IDLE_SECS}s idle"
for d in "${DEVS[@]}"; do
  ( blkdiscard "$d" >/dev/null 2>&1 && echo "  blkdiscard $d: ok" \
      || echo "  !! blkdiscard $d FAILED — NO SLC reset (discard unsupported on this namespace?)" ) &
done
wait
sleep "$IDLE_SECS"

# confine randwrite to a per-device working set (fresh-SLC start, like fig-7b's 10G)
WSET_SIZE="${WSET_SIZE:-10G}"
job="$(mktemp)"
sed -E -e "s/^size=.*/size=${WSET_SIZE}/" "$FIOFILE" > "$job"
grep -q '^size=' "$job" || sed -i "0,/^\[global\]/s//[global]\nsize=${WSET_SIZE}/" "$job"
i=0; for d in "${DEVS[@]}"; do printf '\n[dev%d]\nfilename=%s\n' "$i" "$d" >> "$job"; i=$((i+1)); done

kill_fio() {
  kill -TERM "$1" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
  pkill -9 -x fio 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

fio "$job" --output-format=json --output="$OUT/$LABEL.json" 2>"$OUT/$LABEL.err" &
fpid=$!

prev=$(cat "$TX95"); prev_t=$(date +%s.%N)
tps=(); steady=0; early=0
for _ in $(seq 1 "$MAX_SAMPLE_SECS"); do
    kill -0 "$fpid" 2>/dev/null || { early=1; break; }
    sleep 1
    cur=$(cat "$TX95"); cur_t=$(date +%s.%N)
    g=$(awk -v a="$prev" -v b="$cur" -v t0="$prev_t" -v t1="$cur_t" 'BEGIN{dt=t1-t0; printf "%.4f",(dt>0)?(b-a)/dt/1e9:0}')
    tps+=("$g"); prev="$cur"; prev_t="$cur_t"
    [[ -n "$DEBUG_CURVE" ]] && echo "  [t=${#tps[@]}s] ${g} GB/s"
    if (( ${#tps[@]} >= WARMUP_SECS + STEADY_WINDOW )); then
        win=("${tps[@]: -STEADY_WINDOW}")
        cov=$(printf '%s\n' "${win[@]}" | awk '{s+=$1;ss+=$1*$1;n++} END{m=s/n;v=ss/n-m*m;sd=(v>0)?sqrt(v):0;printf "%.3f",(m>0)?100*sd/m:999}')
        awk -v c="$cov" -v th="$STEADY_THRESH" 'BEGIN{exit !(c<th)}' && { steady=1; break; }
    fi
done

if [[ "$early" -eq 1 ]]; then wait "$fpid" 2>/dev/null || true; else kill_fio "$fpid"; fi
rm -f "$job"
if (( ${#tps[@]} < WARMUP_SECS + STEADY_WINDOW )); then
    echo "  fio produced too few samples (${#tps[@]}) — see $LABEL.err:"; sed 's/^/    /' "$OUT/$LABEL.err"; exit 1
fi

win=("${tps[@]: -STEADY_WINDOW}")
read -r steady_gbps cov_pct <<<"$(printf '%s\n' "${win[@]}" | awk '{s+=$1;ss+=$1*$1;n++} END{m=s/n;v=ss/n-m*m;sd=(v>0)?sqrt(v):0;printf "%.2f %.2f",m,(m>0)?100*sd/m:0}')"
[[ "$steady" -eq 1 ]] && tag="steady" || tag="NOT-converged(capped ${MAX_SAMPLE_SECS}s)"

python3 - "$OUT/$LABEL.json" "$LABEL" "$steady_gbps" "$cov_pct" "$tag" "$SUMMARY" <<'PY'
import json, sys
jf, label, steady, cov, tag, summ = sys.argv[1:]
try:
    raw = open(jf).read()
    jobs = json.loads(raw[raw.index('{'):])['jobs']
    mbps = kiops = 0.0; clats = []
    for jb in jobs:
        wr = jb['write']
        mbps  += wr['bw'] / 1024.0
        kiops += wr['iops'] / 1000.0
        c = wr.get('clat_ns', wr.get('lat_ns', {})).get('mean', 0)
        if c: clats.append(c)
    clat = (sum(clats)/len(clats)/1000.0) if clats else 0.0
except Exception:
    mbps = kiops = clat = 0.0
print("  net TX %s (.95): %s GB/s  (CoV %s%%)   (fio %.0f MiB/s, %.1f kIOPS, clat %.1f us)"
      % (tag, steady, cov, mbps, kiops, clat))
open(summ,'a').write(f"{label},{steady},{cov},{mbps:.1f},{kiops:.1f},{clat:.1f}\n")
PY
