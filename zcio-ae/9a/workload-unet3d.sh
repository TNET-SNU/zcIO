#!/bin/bash
# workload-unet3d.sh — fig-9a MLPerf Storage UNet3D workload (one config).
#
#   Usage:  ./workload-unet3d.sh <config> [outdir]    (config = default | zcIO)
#
# Assumes NVMe/TCP is ALREADY connected (the orchestrator brought the stack up).
# Procedure (from nvme connect onward):
#   0) all CPUs ON         (set-cores.sh all)
#   1) mount the 4 devices (mount_4disk.sh)
#   2) set permissions     (mlperf test dir: ./setup_permissions.sh)
#   3) activate venv
#   4) write UNet3D dataset (./setup_4disk_simple.sh)
#   5) CPU down to 1       (set-cores.sh single)
#   6) run UNet3D, watch ens2np0 incoming bandwidth for WATCH_SEC seconds,
#      record the PEAK Gbps over that window, then stop the run. That peak is
#      the per-experiment result used for the plot later.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

CFG="${1:?usage: $0 <config> [outdir]}"
OUTDIR="${2:-results}"; mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
WL="unet3d"

# ---- paths / knobs (CONFIRM these for your box) ---------------------------
HERE="$(dirname "$(readlink -f "$0")")"                  # fig-9a dir (set-cores.sh lives here)
# CPU on/off: use fig-9a's set-cores.sh (NOPASSWD, self-execs sudo). ~/cpu_on.sh
# and ~/cpu_off.sh write /sys/.../online directly -> need root -> fail when this
# script runs as a normal user. set-cores.sh: 'all'=all cores on, 'single'=1 core.
SETCORES="${SETCORES:-$HERE/set-cores.sh}"
MOUNT_SH="${MOUNT_SH:-./mount_4disk.sh}" # mount the 4 NVMe/TCP devices  (CONFIRM path)
MLPERF_DIR="${MLPERF_DIR:-/opt/mlperf-env/mlperf_storage/test}"
VENV="${VENV:-/opt/mlperf-env/venv/bin/activate}"
DATA_NIC="${DATA_NIC:-ens2np0}"                          # NIC whose INCOMING traffic we measure
WATCH_SEC="${WATCH_SEC:-40}"                            # watch incoming for this long, record the PEAK, then stop
SAMPLE_SEC="${SAMPLE_SEC:-1}"                            # bandwidth sampling interval
RUN_SH="${RUN_SH:-./run_unet3d_simple.sh}"              # the actual UNet3D run script (in MLPERF_DIR)

LOG="$OUTDIR/${WL}-${CFG}.log"
CSV="$OUTDIR/${WL}-${CFG}.csv"
RXFILE="/sys/class/net/${DATA_NIC}/statistics/rx_bytes"

echo "[$WL] config=$CFG  nic=$DATA_NIC  watch=${WATCH_SEC}s  log=$LOG"
[[ -r "$RXFILE" ]] || { echo "!! no NIC counter $RXFILE (is $DATA_NIC up?)"; exit 1; }

# 0) all CPUs on (datagen wants full cores)
echo ">>> [0] all CPUs on"
"$SETCORES" all

# 1) mount the connected devices
echo ">>> [1] mount_4disk"
"$MOUNT_SH"

# 2) set permissions on the mounted devices
echo ">>> [2] cd $MLPERF_DIR + setup_permissions"
cd "$HERE" || { echo "!! MLPERF_DIR not found: $MLPERF_DIR"; exit 1; }
for s in setup_permissions.sh setup_4disk_simple.sh run_unet3d_simple.sh; do
    [[ -e "$s" ]] || echo "  !! missing $MLPERF_DIR/$s  (confirm its real location -> set MLPERF_DIR)"
done
./setup_permissions.sh

# 3) activate the mlperf venv
echo ">>> [3] activate venv ($VENV)"
# shellcheck disable=SC1090
source "$VENV"

# 4) write the UNet3D dataset to disk
echo ">>> [4] setup_4disk_simple (datagen)"
./setup_4disk_simple.sh

# 5) single core for the measurement
echo ">>> [5] CPU down to 1"
"$SETCORES" single

# 6) run UNet3D + record PEAK incoming Gbps on $DATA_NIC over a ${WATCH_SEC}s window
echo ">>> [6] run UNet3D, watch $DATA_NIC incoming for ${WATCH_SEC}s (record peak Gbps)"
setsid "$RUN_SH" >"$LOG" 2>&1 &      # own process group so we can kill the whole tree
RUN_PGID=$!

peak=0
end=$((SECONDS + WATCH_SEC))
while [[ $SECONDS -lt $end ]] && kill -0 "$RUN_PGID" 2>/dev/null; do
    b1="$(cat "$RXFILE")"; sleep "$SAMPLE_SEC"; b2="$(cat "$RXFILE")"
    peak="$(awk -v a="$b1" -v b="$b2" -v dt="$SAMPLE_SEC" -v pk="$peak" \
        'BEGIN{ g=(b-a)*8/dt/1e9; printf "%.2f", (g>pk)?g:pk }')"
    printf "\r  %s incoming peak=%.2f Gbps  (%ds left)   " "$DATA_NIC" "$peak" "$((end-SECONDS))"
done
echo
# stop the run AND its whole process tree so nothing keeps the data mount busy
kill -- -"$RUN_PGID" 2>/dev/null || true
pkill -9 -f "$(basename "$RUN_SH")" 2>/dev/null || true   # straggler script
pkill -9 -f 'dlio_benchmark' 2>/dev/null || true          # MLPerf Storage runner (DLIO)
wait "$RUN_PGID" 2>/dev/null || true
sleep 2

# record the peak
echo "workload,config,peak_incoming_gbps" > "$CSV"
echo "$WL,$CFG,$peak" >> "$CSV"
echo "[$WL] config=$CFG  PEAK incoming = ${peak} Gbps  -> $CSV"
