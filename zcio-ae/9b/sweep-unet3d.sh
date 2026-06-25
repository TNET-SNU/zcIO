#!/bin/bash
# sweep-unet3d.sh — fig-9b UNet3D CPU online-core sweep (one config).
#
#   Usage:  ./sweep-unet3d.sh <config> [outdir]    (config = default | zcIO)
#
# Assumes NVMe/TCP is ALREADY connected + mounted (the orchestrator does that).
# For each core count N in CORES it OFFLINES cpus so exactly N stay online
# (set-cores.sh N — NOT taskset; taskset crams all 8 ranks onto a few cores and
# deadlocks at the epoch-end MPI barrier, offlining does not), runs the raw
# mlpstorage UNet3D command, and parses the [METRIC] lines:
#
#   [METRIC] Training Accelerator Utilization [AU] (%): 14.1921 (0.0000)
#   [METRIC] Training Throughput (samples/second): 23.5243 (0.0000)
#   [METRIC] Training I/O Throughput (MB/second): 3288.9139 (0.0000)
#   [METRIC] train_au_meet_expectation: fail
#
# Fixed run (the validated config that reproduces the paper eval):
#   num-accelerators=8, num_files_train=3072 (=8x384, evenly shardable),
#   read_threads=2*cores (per accelerator, scales with cores), epochs=1, odirect=true.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
HERE="$(pwd)"

# GPUs / threads / core sweep live in config.sh — EDIT THERE (env still overrides).
# shellcheck disable=SC1091
[ -f "$HERE/config.sh" ] && source "$HERE/config.sh"

CFG="${1:?usage: $0 <config> [outdir]}"
OUTDIR="${2:-results}"; mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"

# ---- env / knobs (defaults; config.sh / env override) ---------------------
ENV_DIR="${ENV_DIR:-$HERE}"                              # set-cores.sh lives here (fig-9b local)
SETCORES="${SETCORES:-$ENV_DIR/set-cores.sh}"
MLPERF_DIR="${MLPERF_DIR:-/opt/mlperf-env/mlperf_storage/test}"
VENV="${VENV:-/opt/mlperf-env/venv/bin/activate}"
DATA_DIR="${DATA_DIR:-/mnt/rocksdb_test/mlperf_merged}"
CORES=(${CORES:-1 2 4 6 8 10})                          # online-core sweep points
# fixed run params (3072 = 8 x 384 -> ranks even regardless of read_threads, no deadlock)
NUM_ACCEL="${NUM_ACCEL:-8}"
NUM_FILES="${NUM_FILES:-3072}"
# read_threads (per accelerator) SCALES with online cores: rt = THREAD_MULT * cores.
# THREAD_MULT=2 -> each GPU gets 2*cores reader threads (total = 2 * NUM_ACCEL * cores).
# e.g. 10 cores -> 8 accel x 2x10 = 160 reader threads.
THREAD_MULT="${THREAD_MULT:-2}"
ZCIO_THREAD_MULT="${ZCIO_THREAD_MULT:-3}"               # zcIO uses more reader threads/accel; default keeps THREAD_MULT
[[ "$CFG" == zcIO ]] && THREAD_MULT="$ZCIO_THREAD_MULT"
EPOCHS="${EPOCHS:-5}"                                    # run 3 epochs; epoch 1 = cold warm-up
REPORT_EPOCH="${REPORT_EPOCH:-max}"                     # "max" = best AU across epochs; or a number for a fixed epoch
LOW_EPOCH_CORES="${LOW_EPOCH_CORES:-}"                  # these core counts run only LOW_EPOCHS (low-AU points where epochs don't matter)
LOW_EPOCHS="${LOW_EPOCHS:-1}"                           # epochs to run for a LOW_EPOCH_CORES point
MEM_GB="${MEM_GB:-36}"
ACCEL_TYPE="${ACCEL_TYPE:-h100}"
RUN_TIMEOUT="${RUN_TIMEOUT:-3600}"                      # per-point safety cap (s)
DATAGEN="${DATAGEN:-1}"                                  # 1 = chown+datagen after mount (mkfs wiped the data); 0 = skip
PERM_SH="${PERM_SH:-./setup_permissions.sh}"            # chown disks + create mlperf_merged (in MLPERF_DIR)
DATAGEN_SH="${DATAGEN_SH:-./setup_4disk.sh}"            # write unet3d dataset (800/disk) + symlink-merge

CSV="$OUTDIR/coresweep-unet3d-${CFG}.csv"
echo "config,cores,read_threads,au_pct,samples_per_s" > "$CSV"

echo "[sweep-unet3d] config=$CFG  cores=${CORES[*]}  accel=$NUM_ACCEL files=$NUM_FILES  read_threads=${THREAD_MULT}xcores"
[[ -x "$SETCORES" ]] || { echo "!! missing set-cores.sh: $SETCORES"; exit 1; }

cd "$HERE" || { echo "!! MLPERF_DIR not found: $MLPERF_DIR"; exit 1; }
# shellcheck disable=SC1090
source "$VENV"

# --- disk write: permissions + datagen (runs at FULL cores, before the sweep) ---
# mount_4disk.sh mkfs+root-mounts the disks every config, so the unet3d dataset AND
# the mlperf_merged symlink dir are gone each time and must be (re)created here:
#   setup_permissions.sh : sudo chown testdb1..4 + sudo mkdir/chown mlperf_merged
#                          (/mnt/rocksdb_test is ki-owned, so the merge dir needs sudo)
#   setup_4disk.sh       : mlpstorage datagen 800 files/disk x4 + interleaved symlink-merge
if [[ "$DATAGEN" == 1 ]]; then
    echo ">>> [$CFG] setup_permissions (chown disks + create mlperf_merged)"
    $PERM_SH || { echo "!! setup_permissions failed"; exit 1; }
    echo ">>> [$CFG] datagen ($DATAGEN_SH) — full cores, slow (~500 GB)"
    $DATAGEN_SH || { echo "!! datagen failed"; exit 1; }
else
    echo ">>> [$CFG] DATAGEN=0 — skipping permissions+datagen (assuming data present)"
fi

for N in "${CORES[@]}"; do
    echo
    echo "── config=$CFG  online cores=$N ──"
    "$SETCORES" "$N"                                     # offline down to N online cores
    sleep "${SETTLE:-3}"                                  # let the offline settle before launching MPI

    T=$(( THREAD_MULT * N ))                              # read_threads scales with cores (2*N)
    EP="$EPOCHS"                                          # per-core epochs (low-AU cores may run fewer)
    for c in ${MID_EPOCH_CORES:-}; do [[ "$c" == "$N" ]] && EP="${MID_EPOCHS:-2}"; done
    for c in $LOW_EPOCH_CORES; do [[ "$c" == "$N" ]] && EP="$LOW_EPOCHS"; done
    RES="results_${CFG}_cpu${N}"
    LOG="$OUTDIR/unet3d-${CFG}-cpu${N}.log"
    rm -rf "$RES"
    echo "  cores=$N  read_threads=$T (=${THREAD_MULT}x$N)  epochs=$EP"

    timeout "$RUN_TIMEOUT" mlpstorage training run \
        --model unet3d \
        --accelerator-type "$ACCEL_TYPE" \
        --num-accelerators "$NUM_ACCEL" \
        --client-host-memory-in-gb "$MEM_GB" \
        --data-dir "$DATA_DIR" \
        --results-dir "$RES" \
        --params dataset.num_files_train="$NUM_FILES" \
                 reader.odirect=true \
                 reader.read_threads="$T" \
                 train.epochs="$EP" \
        --open --allow-run-as-root --oversubscribe \
        > "$LOG" 2>&1
    rc=$?
    [[ $rc -eq 124 ]] && echo "  !! TIMEOUT after ${RUN_TIMEOUT}s (cores=$N)"

    # Parse per-epoch AU from the per-rank output JSONs (NOT the [METRIC] line, which
    # averages ALL epochs incl. the cold epoch 1). DLIO stores per-epoch AU as
    # "<epoch>.au.block1" in each <rank>_output.json. We rank-average each epoch, then
    # report REPORT_EPOCH: "max" = the BEST epoch's AU (epoch 1 is cold so a steady
    # epoch wins); a number = that specific epoch. samples/s is that same epoch's.
    RUNDIR=$(ls -td "$RES"/training/unet3d/run/*/ 2>/dev/null | head -1)
    read AU SAMP BESTEP < <(python3 - "$RUNDIR" "$REPORT_EPOCH" <<'PY'
import json, glob, os, sys
from collections import defaultdict
rundir, mode = sys.argv[1], sys.argv[2]
au_ep = defaultdict(list); sp_ep = defaultdict(list)
for f in glob.glob(os.path.join(rundir, "*_output.json")):
    try:
        d = json.load(open(f))
        for ep, b in d.items():
            if not isinstance(b, dict): continue
            if isinstance(b.get("au"), dict)         and "block1" in b["au"]:         au_ep[ep].append(float(b["au"]["block1"]))
            if isinstance(b.get("throughput"), dict) and "block1" in b["throughput"]: sp_ep[ep].append(float(b["throughput"]["block1"]))
    except Exception: pass
au_avg = {e: sum(v)/len(v) for e, v in au_ep.items() if v}   # per-epoch, averaged over ranks
if not au_avg:
    print("N/A N/A N/A"); sys.exit()
best = max(au_avg, key=au_avg.get) if mode == "max" else mode
fa = f"{au_avg[best]:.4f}" if best in au_avg else "N/A"
sv = sp_ep.get(best, [])
fs = f"{sum(sv)/len(sv):.4f}" if sv else "N/A"
print(fa, fs, best)
PY
)
    AU=${AU:-N/A}; SAMP=${SAMP:-N/A}; BESTEP=${BESTEP:-N/A}

    echo "$CFG,$N,$T,$AU,$SAMP" >> "$CSV"
    printf "  → cores=%-2s thr=%-3s  AU=%-8s (best epoch %s/%s)  samples/s=%s\n" "$N" "$T" "$AU" "$BESTEP" "$EP" "$SAMP"
done

# restore all cores for the next config's connect / a clean machine
"$SETCORES" all
echo
echo "[sweep-unet3d] config=$CFG done -> $CSV"
