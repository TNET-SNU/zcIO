#!/bin/bash
# workload-llama3.sh — fig-9a MLPerf Storage LLaMA3-8B checkpoint-load workload (one config).
#
#   Usage:  ./workload-llama3.sh <config> [outdir]    (config = default | zcIO)
#
# Single-point bandwidth measurement, same metric as the other fig-9a workloads
# (PEAK ens2np0 incoming Gbps). LLaMA3 measures CHECKPOINT READ (load_state):
#
#   1) make_llama_disk.sh  : write a llama3-8b checkpoint (.pt) to testdb1
#   2) dio_bench.py convert : .pt -> .safetensors  (testdb1, O_DIRECT-readable)
#   3) dio_bench.py distribute : spread the rank files over the 4 NETWORK disks
#                                (dio_bench.py DISK_ROOTS = testdb1~4; testdb5~8
#                                 are commented out so nothing leaks to local fs)
#   4) dio_bench.py run --mode safetensors : parallel O_DIRECT read of the
#      distributed checkpoint. Single core via dio_bench's own --read-cores 1
#      (no core offlining needed — it pins the read itself).
#
# Procedure (NVMe/TCP is ALREADY connected by the orchestrator):
#   0) all CPUs ON          (set-cores.sh all)
#   1) mount the 4 devices  (mount_4disk.sh)
#   2) set permissions      (./setup_permissions.sh)
#   3) activate venv
#   4) write + convert + distribute the checkpoint (prep, full cores)
#   5) run the safetensors read (--read-cores 1), watch ens2np0 incoming for
#      WATCH_SEC, record the PEAK Gbps, then stop.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

CFG="${1:?usage: $0 <config> [outdir]}"
OUTDIR="${2:-results}"; mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
WL="llama3"

# ---- paths / knobs --------------------------------------------------------
HERE="$(dirname "$(readlink -f "$0")")"                  # fig-9a dir (set-cores.sh lives here)
SETCORES="${SETCORES:-$HERE/set-cores.sh}"
MOUNT_SH="${MOUNT_SH:-./mount_4disk.sh}"
MLPERF_DIR="${MLPERF_DIR:-/opt/mlperf-env/mlperf_storage/test}"
VENV="${VENV:-/opt/mlperf-env/venv/bin/activate}"
DATA_NIC="${DATA_NIC:-ens2np0}"                          # measure INCOMING traffic here
WATCH_SEC="${WATCH_SEC:-40}"                             # watch incoming, record the PEAK, then stop
SAMPLE_SEC="${SAMPLE_SEC:-1}"
DATAGEN_SH="${DATAGEN_SH:-./make_llama_disk.sh}"         # write llama3-8b checkpoint to testdb1
DIO="${DIO:-dio_bench.py}"                               # convert / distribute / run driver
DISKS="${DISKS:-4}"                                      # network disks (dio_bench DISK_ROOTS=testdb1~4)
RANKS="${RANKS:-8}"                                      # 4 disks x RANKS_PER_DISK(2)
READ_CORES="${READ_CORES:-1}"                            # single-core read
THREADS_PER_DISK="${THREADS_PER_DISK:-1}"               # dio_bench --threads-per-disk (total = disks x tpd = 16)
REPEATS="${REPEATS:-3}"

LOG="$OUTDIR/${WL}-${CFG}.log"
CSV="$OUTDIR/${WL}-${CFG}.csv"
RXFILE="/sys/class/net/${DATA_NIC}/statistics/rx_bytes"

echo "[$WL] config=$CFG  nic=$DATA_NIC  watch=${WATCH_SEC}s  log=$LOG"
[[ -r "$RXFILE" ]] || { echo "!! no NIC counter $RXFILE (is $DATA_NIC up?)"; exit 1; }

# 0) all CPUs on (write/convert/distribute want full cores)
echo ">>> [0] all CPUs on"
"$SETCORES" all

# 1) mount the connected devices
echo ">>> [1] mount_4disk"
"$MOUNT_SH"

# 2) permissions
echo ">>> [2] cd $MLPERF_DIR + setup_permissions"
cd "$HERE" || { echo "!! MLPERF_DIR not found: $MLPERF_DIR"; exit 1; }
for s in setup_permissions.sh "$DATAGEN_SH" "$DIO"; do
    [[ -e "$s" ]] || echo "  !! missing $MLPERF_DIR/$s  (confirm location -> set MLPERF_DIR/DATAGEN_SH/DIO)"
done
./setup_permissions.sh

# 3) venv
echo ">>> [3] activate venv ($VENV)"
# shellcheck disable=SC1090
source "$VENV"

# 4) prep: write checkpoint -> convert to safetensors -> distribute over 4 disks
echo ">>> [4a] write llama3-8b checkpoint ($DATAGEN_SH)"
$DATAGEN_SH
echo ">>> [4b] convert .pt -> .safetensors (dio_bench convert)"
python3 "$DIO" convert
echo ">>> [4c] distribute rank files over $DISKS network disks (dio_bench distribute)"
python3 "$DIO" distribute

# 5) run the safetensors O_DIRECT read + record PEAK incoming Gbps on $DATA_NIC
echo ">>> [5] dio_bench run --mode safetensors --disks $DISKS --read-cores $READ_CORES"
setsid bash -c "python3 '$DIO' run --mode safetensors --disks $DISKS --ranks $RANKS --read-cores $READ_CORES --threads-per-disk $THREADS_PER_DISK --repeats $REPEATS" >"$LOG" 2>&1 &
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
pkill -9 -f 'dio_bench.py' 2>/dev/null || true
wait "$RUN_PGID" 2>/dev/null || true
sleep 2

# record the peak
echo "workload,config,peak_incoming_gbps" > "$CSV"
echo "$WL,$CFG,$peak" >> "$CSV"
echo "[$WL] config=$CFG  PEAK incoming = ${peak} Gbps  -> $CSV"
