#!/bin/bash
# workload-cosmoflow.sh — fig-9a MLPerf Storage CosmoFlow workload (one config).
#
#   Usage:  ./workload-cosmoflow.sh <config> [outdir]    (config = default | zcIO)
#
# Same single-point bandwidth measurement as workload-unet3d.sh. CosmoFlow uses
# the NPZ data format (not the MLPerf default TFRecord): TFRecord can't do
# O_DIRECT, NPZ can, so with reader.odirect=true every read bypasses the page
# cache and actually hits the NVMe/TCP path. Every cosmoflow command carries:
#       dataset.format=npz reader.odirect=true reader.data_loader=pytorch
#
# Data lives on the 4 NETWORK disks only (testdb1~4 = nvme/tcp). make_cosmo_disk.sh
# was fixed to use 4 disks — testdb5~8 are LOCAL rootfs, and putting data there
# leaks half the reads off the network so the NIC counter only sees half.
#
# Single core via set-cores single (offline). run_cosmo_read.sh sets the MPI
# yield knobs (OMPI_MCA_mpi_yield_when_idle / opal_progress_lp_call_yield) so the
# accel procs don't livelock when there are more procs than online cores.
#
# Procedure (NVMe/TCP is ALREADY connected by the orchestrator):
#   0) all CPUs ON          (set-cores.sh all — datagen wants full cores)
#   1) mount the 4 devices  (mount_4disk.sh)
#   2) set permissions      (./setup_permissions.sh)
#   3) activate venv
#   4) write CosmoFlow NPZ dataset on 4 net disks (./make_cosmo_disk.sh)
#   5) CPU down to 1        (set-cores.sh single)
#   6) run run_cosmo_read.sh, watch ens2np0 incoming for WATCH_SEC, record the
#      PEAK Gbps, then stop the run.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

CFG="${1:?usage: $0 <config> [outdir]}"
OUTDIR="${2:-results}"; mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
WL="cosmoflow"

# ---- paths / knobs --------------------------------------------------------
HERE="$(dirname "$(readlink -f "$0")")"                  # fig-9a dir (set-cores.sh lives here)
SETCORES="${SETCORES:-$HERE/set-cores.sh}"
MOUNT_SH="${MOUNT_SH:-./mount_4disk.sh}"
MLPERF_DIR="${MLPERF_DIR:-/opt/mlperf-env/mlperf_storage/test}"
VENV="${VENV:-/opt/mlperf-env/venv/bin/activate}"
DATA_NIC="${DATA_NIC:-ens2np0}"                          # measure INCOMING traffic here
WATCH_SEC="${WATCH_SEC:-20}"                             # watch incoming, record the PEAK, then stop
SAMPLE_SEC="${SAMPLE_SEC:-1}"
DATAGEN_SH="${DATAGEN_SH:-./make_cosmo_disk.sh}"         # NPZ datagen + symlink-merge (4 net disks)
RUN_SH="${RUN_SH:-./run_cosmo_read.sh}"                  # cosmoflow run (MPI yield -> single-core safe)

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

# 2) permissions
echo ">>> [2] cd $MLPERF_DIR + setup_permissions"
cd "$HERE" || { echo "!! MLPERF_DIR not found: $MLPERF_DIR"; exit 1; }
for s in setup_permissions.sh "$DATAGEN_SH" "$RUN_SH"; do
    [[ -e "$s" ]] || echo "  !! missing $MLPERF_DIR/$s  (confirm location -> set MLPERF_DIR/DATAGEN_SH/RUN_SH)"
done
./setup_permissions.sh

# 3) venv
echo ">>> [3] activate venv ($VENV)"
# shellcheck disable=SC1090
source "$VENV"

# 4) generate the CosmoFlow NPZ dataset (8000 files over 4 net disks) + symlink-merge
echo ">>> [4] cosmoflow NPZ datagen ($DATAGEN_SH) — slow"
$DATAGEN_SH

# 5) single core for the measurement
echo ">>> [5] CPU down to 1"
"$SETCORES" single

# 6) run cosmoflow + record PEAK incoming Gbps on $DATA_NIC over a ${WATCH_SEC}s window
echo ">>> [6] run cosmoflow, watch $DATA_NIC incoming for ${WATCH_SEC}s (record peak Gbps)"
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
pkill -9 -f "$(basename "$RUN_SH")" 2>/dev/null || true
pkill -9 -f 'mlpstorage'     2>/dev/null || true
pkill -9 -f 'dlio_benchmark' 2>/dev/null || true   # MLPerf Storage runner (DLIO)
pkill -9 -f 'pt_data_worker' 2>/dev/null || true
wait "$RUN_PGID" 2>/dev/null || true
sleep 2

# record the peak
echo "workload,config,peak_incoming_gbps" > "$CSV"
echo "$WL,$CFG,$peak" >> "$CSV"
echo "[$WL] config=$CFG  PEAK incoming = ${peak} Gbps  -> $CSV"
