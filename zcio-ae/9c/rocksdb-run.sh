#!/bin/bash
# rocksdb-run.sh — fig-9a single-core RocksDB read-IOPS sweep (one config).
#
# Reproduces one column-set of the fig-9a RocksDB table: for each block size,
# build the 4-disk DB (make_4disks.sh) then measure readrand IOPS (read_4disks.sh)
# REPS times and average. Pinned to a SINGLE core (all cores but cpu0 offlined),
# matching the paper's single-core point-lookup setup.
#
# Per-block-size knobs (from your table):
#     bs:            4k     32k    64k    128k   256k
#     per-disk-file: 1024   1024   4096   4096   1024     (NUM_RECORDS, = key space/disk)
#     read threads:  512    1024   256    128    128
#
# This script does NOT change zcopy/pdu_align — it measures whatever config is
# currently live. Run it once per config, after bringing that config up:
#     default (Linux):  fig-9a setup.sh  (zcopy_off + nvme_pdu_align=0)   -> sudo ./rocksdb-run.sh default
#     zcIO          :  NET_PDU=2 setup.sh + zcopy_on.sh (zcopy_on + pdu=2)-> sudo ./rocksdb-run.sh zcIO
#   (Always pair the knobs: zcopy ON must go with pdu_align ON, else the
#    zero-copy RX path receives misaligned PDUs and corrupts reads.)
#
# Prereqs (do these first, per config):
#   1) fig-9a ./setup.sh           — 4 NVMe/TCP subsystems connected, full cores
#   2) ./mount_4disk.sh            — mkfs + mount the 4 devices on /mnt/rocksdb_test
#
# Usage:  sudo ./rocksdb-run.sh <label>          (label tags the output, e.g. default|zcIO)
# Output: results-rocksdb-<label>.csv  +  a printed bs x rep table.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

[[ $EUID -eq 0 ]] || { echo "Run with sudo (core offline + reads need root):  sudo $0 $*"; exit 1; }

LABEL="${1:-run}"
BATCH_ALL="${2:-}"                      # arg2 (survives sudo): if set, force ALL bs to this batch
REPS="${3:-${REPS:-4}}"                # arg3 (survives sudo): reps override (env REPS as fallback)
THREADS_ALL="${4:-}"                    # arg4 (survives sudo): if set, force ALL bs to this thread count
MODE="${MODE:-readrand}"
ONLY_BS="${5:-${ONLY_BS:-}}"           # arg5 (survives sudo) or env: measure ONLY this block size
PIN="${6:-offline}"                     # arg6: 'offline' (offline cpu1+) | 'taskset' (cores online, pin app to cpu0)
PIN_CPU="${PIN_CPU:-0}"                 # cpu to pin to when PIN=taskset
FILL_THREADS="${FILL_THREADS:-16}"     # fill is single-loop internally; just needs %4==0
FILL_BATCH="${FILL_BATCH:-256}"        # DB-fill batch (make_4disks); NOT part of the measurement
DB_BASE="/mnt/rocksdb_test"

# ---- per-config parameter sets (index-aligned with BS_NAMES) --------------
# default and zcIO are each tuned to their OWN single-core saturation point
# (the params that drive the core to peak throughput). Picked by LABEL:
#   LABEL contains "zcIO"/"zc" -> zcIO set ; otherwise -> default set.
# The values actually used are recorded per-row in the CSV (threads,batch,
# per_disk_file) so the comparison stays transparent/reproducible.
#                4k     32k    64k    128k   256k
BS_NAMES=(       4k     32k    64k    128k   256k)
VSIZE=(          4096   32768  65536  131072 262144)   # value/block size (bytes)

case "$LABEL" in 					#best iops performance parameters for each(zcio, default) case
  *zcIO*|*zcio*|*zc*)
    CFG_TAG="zcIO"
    #          4k      32k     64k    128k   256k
    NREC=(     1024    1024    1024   1024   1024)
    THREADS=(  1024    1024    512    128    128)
    BATCH=(    512     512     512    512    512)
    OPS=(      1000000 1000000 500000 500000 50000)
    ;;
  *)
    CFG_TAG="default"
    #          4k      32k     64k    128k   256k
    NREC=(     1024    1024    1024   1024   1024)
    THREADS=(  1024    1024    1024   512    256)
    BATCH=(    512     512     512    512    512)
    OPS=(      1000000 1000000 500000 500000 50000)
    ;;
esac
echo "[run] config=$CFG_TAG  threads=(${THREADS[*]})  batch=(${BATCH[*]})  perdisk=(${NREC[*]})"
# per-bs OPS env override still works:  OPS_4k=2000000 sudo ./rocksdb-run.sh ...

# arg2 override: force every block size to the same batch (for batch sweeps).
if [[ -n "$BATCH_ALL" ]]; then
    for i in "${!BATCH[@]}"; do BATCH[$i]="$BATCH_ALL"; done
    echo "[run] BATCH_ALL=$BATCH_ALL -> all bs use batch=$BATCH_ALL"
fi
if [[ -n "$THREADS_ALL" ]]; then
    for i in "${!THREADS[@]}"; do THREADS[$i]="$THREADS_ALL"; done
    echo "[run] THREADS_ALL=$THREADS_ALL -> all bs use threads=$THREADS_ALL"
fi

OUT="results-rocksdb-${LABEL}.csv"
# ---------------------------------------------------------------------------

# --- single-core helpers (cpu0 can't be offlined) --------------------------
set_cores() {  # 1=offline all but cpu0 ; 0=online all
    local want_offline="$1" c id
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        id="${c##*/cpu}"; [[ "$id" == "0" ]] && continue
        [[ -w "$c/online" ]] || continue
        if [[ "$want_offline" == 1 ]]; then echo 0 > "$c/online"; else echo 1 > "$c/online"; fi
    done
    echo "[cores] online CPUs now: $(nproc)  ($(cat /sys/devices/system/cpu/online))"
}

# --- prechecks -------------------------------------------------------------
for i in 1 2 3 4; do
    mountpoint -q "$DB_BASE/testdb$i" \
        || { echo "ERROR: $DB_BASE/testdb$i not mounted — run ./mount_4disk.sh first"; exit 1; }
done
ndev=$(ls -d /sys/class/nvme/nvme*/ 2>/dev/null | wc -l)
zc=$(cat /sys/module/nvme_tcp/parameters/enable_zerocopy 2>/dev/null || echo '?')
echo "[run] label=$LABEL  reps=$REPS  enable_zerocopy=$zc  (rapids0 pdu_align set separately)"
echo "[run] NOTE: confirm this matches '$LABEL' (default=>zc 0, zcIO=>zc 1)."

# --- go: single core for the whole sweep -----------------------------------
CPU_LIST=""
case "$PIN" in
    taskset)
        CPU_LIST="$PIN_CPU"     # leave ALL cores online; pin app to cpu via taskset in read_4disks
        echo "[run] PIN=taskset -> all cores online, app pinned to cpu $PIN_CPU (kernel I/O on all cores)" ;;
    none)
        echo "[run] PIN=none -> CPU on/off NOT touched (managed externally; runs on whatever is online)" ;;
    *)
        trap 'echo "[cores] restoring all cores online"; set_cores 0' EXIT
        set_cores 1 ;;          # offline cpu1+ (default single-core method)
esac

echo "bs,rep,threads,batch,per_disk_file,ops_per_s,avg_us,notfound" > "$OUT"
declare -A AVG

for k in "${!BS_NAMES[@]}"; do
    bs="${BS_NAMES[$k]}"; v="${VSIZE[$k]}"; nr="${NREC[$k]}"; t="${THREADS[$k]}"; b="${BATCH[$k]}"; ops="${OPS[$k]}"
    # ONLY_BS filter: skip every block size except the requested one.
    [[ -n "$ONLY_BS" && "$bs" != "$ONLY_BS" ]] && continue
    # per-bs OPS override:  OPS_4k=2000000 sudo ./rocksdb-run.sh ...
    eval "ops=\${OPS_${bs}:-$ops}"

    echo
    echo "############ bs=$bs  (vsize=$v  per-disk-file=$nr  threads=$t  batch=$b  ops=$ops) ############"
    echo "[make] building 4-disk DB ..."
    if ! ./make_4disks.sh "$v" "$FILL_THREADS" "$FILL_BATCH" "$nr" >/tmp/make_${bs}.log 2>&1; then
        echo "  !! make_4disks failed (see /tmp/make_${bs}.log); skipping bs=$bs"; continue
    fi

    sum=0; nrun=0; ausum=0
    for r in $(seq 1 "$REPS"); do
        echo "  --- rep$r (live read_4disks output) ---------------------------------"
        # tee: stream the ORIGINAL read_4disks output (incl. the mode=... ops/s=...
        # avg_us=... line) to the terminal live, while capturing it to parse.
        tmp="$(mktemp)"
        ./read_4disks.sh "$MODE" "$ops" "$t" "$b" "$nr" "$CPU_LIST" 2>&1 | sed 's/^/    | /' | tee "$tmp"
        out="$(cat "$tmp")"; rm -f "$tmp"
        iops="$(printf '%s\n' "$out" | grep -oE 'ops/s=[0-9.]+'   | tail -1 | cut -d= -f2)"
        nf="$(  printf '%s\n' "$out" | grep -oE 'notfound=[0-9]+' | tail -1 | cut -d= -f2)"
        aus="$( printf '%s\n' "$out" | grep -oE 'avg_us=[0-9.]+'  | tail -1 | cut -d= -f2)"
        [[ -n "$iops" ]] || { echo "  rep$r: PARSE FAIL"; continue; }
        printf "  rep%d PARSED: ops/s=%-12s avg_us=%-10s notfound=%s\n" "$r" "$iops" "${aus:-?}" "${nf:-?}"
        echo "$bs,$r,$t,$b,$nr,$iops,${aus:-},${nf:-}" >> "$OUT"
        sum="$(awk -v a="$sum" -v b="$iops" 'BEGIN{printf "%.4f", a+b}')"; nrun=$((nrun+1))
        ausum="$(awk -v a="$ausum" -v b="${aus:-0}" 'BEGIN{printf "%.4f", a+b}')"
        [[ "${nf:-0}" -gt 0 ]] && echo "      ^ WARNING: notfound>0 — read corruption/misconfig (check zcopy+pdu pairing)"
    done
    if [[ "$nrun" -gt 0 ]]; then
        avg="$(awk -v s="$sum" -v n="$nrun" 'BEGIN{printf "%.2f", s/n}')"
        auavg="$(awk -v s="$ausum" -v n="$nrun" 'BEGIN{printf "%.2f", s/n}')"
        AVG[$bs]="$avg"
        echo "  -> bs=$bs  AVG ops/s = $avg   avg_us = $auavg   (over $nrun reps)"
        echo "$bs,avg,$t,$b,$nr,$avg,$auavg," >> "$OUT"
    fi
done

echo
echo "############################ SUMMARY ($LABEL) ############################"
printf "%-8s %-12s %-8s %-8s %s\n" "bs" "avg_ops/s" "threads" "batch" "per_disk_file"
for k in "${!BS_NAMES[@]}"; do
    bs="${BS_NAMES[$k]}"
    printf "%-8s %-12s %-8s %-8s %s\n" "$bs" "${AVG[$bs]:-NA}" "${THREADS[$k]}" "${BATCH[$k]}" "${NREC[$k]}"
done
echo
echo "Per-rep rows + averages: $OUT"
echo "Run the other config the same way, then plot the two CSVs together."
