#!/bin/bash
# batch-sweep.sh — autonomous search for the read-batch (--batch_n) that best
# reproduces the reference single-core RocksDB IOPS table (default + zcIO).
#
# Per config we bring the stack up ONCE (the NVMe/TCP connection persists), then
# for each batch value: unmount -> mkfs+mount -> rocksdb-run.sh <label> <batch>
# <reps>. Finally every batch is scored against the embedded reference.
#
#   Usage:  ./batch-sweep.sh [batch ...]
#   Env:    CONFIGS="default zcIO"  REPS=4  ROCKSDB_DIR=~/rocksdb_test
#
# Needs NOPASSWD (sudo -n) for ROCKSDB_DIR/{mount_4disk,unmount_4disk,rocksdb-run}.sh
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

ROCKSDB_DIR="${ROCKSDB_DIR:-/opt/rocksdb-env}"
CONFIGS=(${CONFIGS:-default zcIO})
REPS="${REPS:-4}"
BATCHES=("$@"); [[ ${#BATCHES[@]} -gt 0 ]] || BATCHES=(16 32 64 128 256)

pdu_for() { case "$1" in default) echo 0 ;; zcIO) echo 2 ;; esac; }
zc_for()  { case "$1" in default) echo off ;; zcIO) echo on ;; esac; }

echo "############################################################"
echo "# batch-sweep: configs=[${CONFIGS[*]}]  batches=[${BATCHES[*]}]  reps=$REPS"
echo "############################################################"

for s in mount_4disk.sh unmount_4disk.sh rocksdb-run.sh; do
    sudo -n -l "$ROCKSDB_DIR/$s" >/dev/null 2>&1 \
        || { echo "!! NOPASSWD missing for $ROCKSDB_DIR/$s — cannot run unattended"; exit 1; }
done

for cfg in "${CONFIGS[@]}"; do
    pdu="$(pdu_for "$cfg")"; zc="$(zc_for "$cfg")"
    echo
    echo "============================================================"
    echo "===  CONFIG = $cfg  (ZCOPY=$zc nvme_pdu_align=$pdu)  ========"
    echo "============================================================"
    echo ">>> [$cfg] disconnect + setup (once) ..."
    ./disconnect.sh || true
    if ! NET_PDU="$pdu" ZCOPY="$zc" ./setup.sh >"/tmp/sweep-setup-$cfg.log" 2>&1; then
        echo "!! setup failed for $cfg (see /tmp/sweep-setup-$cfg.log) — skipping config"; continue
    fi
    echo "    setup OK ($(grep -c 'namespace' /tmp/sweep-setup-$cfg.log >/dev/null 2>&1; echo connected))"

    for batch in "${BATCHES[@]}"; do
        label="b${batch}-${cfg}"
        echo; echo ">>> [$cfg batch=$batch] mkfs+mount + rocksdb-run (reps=$REPS) ..."
        sudo -n "$ROCKSDB_DIR/unmount_4disk.sh" >/dev/null 2>&1 || true
        if ! sudo -n "$ROCKSDB_DIR/mount_4disk.sh" >"/tmp/sweep-mount-$label.log" 2>&1; then
            echo "    !! mount failed (see /tmp/sweep-mount-$label.log)"; continue
        fi
        sudo -n "$ROCKSDB_DIR/rocksdb-run.sh" "$label" "$batch" "$REPS" 2>&1 \
            | tee "/tmp/sweep-run-$label.log" \
            | grep -E '^(\[run\]|############ bs=|  -> bs=)' || true
        [[ -f "$ROCKSDB_DIR/results-rocksdb-$label.csv" ]] \
            && cp "$ROCKSDB_DIR/results-rocksdb-$label.csv" "./results-rocksdb-$label.csv"
    done
done

echo; echo ">>> cleanup ..."
sudo -n "$ROCKSDB_DIR/unmount_4disk.sh" >/dev/null 2>&1 || true
./disconnect.sh || true

echo
echo "############################################################"
echo "# SCORE vs reference (avg ops/s; err% = |meas-ref|/ref)"
echo "############################################################"
python3 - "${BATCHES[@]}" <<'PY'
import csv, os, sys
batches = sys.argv[1:]
order = ["4k","32k","64k","128k","256k"]
REF = {
 "default": {"4k":99036, "32k":45557, "64k":29802.75, "128k":17904, "256k":6416.25},
 "zcIO":    {"4k":99901, "32k":51412.25, "64k":43077.75, "128k":28213.25, "256k":9923.75},
}
def avgs(label):
    p = f"results-rocksdb-{label}.csv"; out = {}
    if not os.path.exists(p): return out
    for row in csv.DictReader(open(p)):
        if row.get("rep") == "avg":
            try: out[row["bs"]] = float(row["ops_per_s"])
            except: pass
    return out
best = None
for b in batches:
    print(f"\n=== batch={b} ===")
    total_err = 0.0; n = 0
    for cfg in ("default","zcIO"):
        m = avgs(f"b{b}-{cfg}")
        if not m: print(f"  {cfg}: (no data)"); continue
        print(f"  {cfg:<8} " + "  ".join(f"{bs}={m.get(bs,0):.0f}(ref{REF[cfg][bs]:.0f},{abs(m.get(bs,0)-REF[cfg][bs])/REF[cfg][bs]*100:.0f}%)" for bs in order))
        for bs in order:
            if bs in m: total_err += abs(m[bs]-REF[cfg][bs])/REF[cfg][bs]; n += 1
    if n:
        mean_err = total_err/n*100
        print(f"  -> mean err = {mean_err:.1f}%  over {n} points")
        if best is None or mean_err < best[1]: best = (b, mean_err)
if best:
    print(f"\n*** BEST batch = {best[0]}  (mean err {best[1]:.1f}%) ***")
PY
