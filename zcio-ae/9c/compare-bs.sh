#!/bin/bash
# compare-bs.sh — fig-9a: default-vs-zcIO for a SINGLE block size only.
#
# Same machinery as all-in-one.sh, but measures just ONE bs (default 64k) so you
# can iterate fast on one point. For each config it brings the whole stack to
# that config, rebuilds the 4-disk DB, and runs rocksdb-run.sh with ONLY_BS=<bs>
# (rocksdb-run offlines to a single core for the measurement itself):
#
#   default (Linux):  ZCOPY=off + nvme_pdu_align=0
#   zcIO          :  ZCOPY=on  + nvme_pdu_align=2
#
#   Usage:  ./compare-bs.sh [bs]          # bs in: 4k 32k 64k 128k 256k  (default 64k)
#   Subset: CONFIGS="zcIO" ./compare-bs.sh 64k
#
# Per-config CSV: results-rocksdb-<bs>-<cfg>.csv  (kept separate from the full
# sweep's results-rocksdb-<cfg>.csv so it won't clobber them).
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

BS="${1:-64k}"
case "$BS" in 4k|32k|64k|128k|256k) ;; *) echo "bs must be one of: 4k 32k 64k 128k 256k (got '$BS')"; exit 1 ;; esac

RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
RAPIDS0_DIR="${RAPIDS0_DIR:-$HOME/zcio-ae-9c}"
ROCKSDB_DIR="${ROCKSDB_DIR:-/opt/rocksdb-env}"
CONFIGS=(${CONFIGS:-default zcIO})

pdu_for() { case "$1" in default) echo 0 ;; zcIO) echo 2 ;; *) echo "" ;; esac; }
zc_for()  { case "$1" in default) echo off ;; zcIO) echo on ;; *) echo "" ;; esac; }

# ----- preflight ------------------------------------------------------
echo ">>> preflight (bs=$BS) ..."
sudo -n -l "$(pwd)/connect.sh" >/dev/null 2>&1 \
    || { echo "!! stream5 NOPASSWD missing — run ./deploy.sh first"; exit 1; }
for f in mount_4disk.sh unmount_4disk.sh make_4disks.sh read_4disks.sh rocksdb-run.sh custom_rocksdb; do
    [[ -e "$ROCKSDB_DIR/$f" ]] || { echo "!! missing $ROCKSDB_DIR/$f (set ROCKSDB_DIR?)"; exit 1; }
done
for cfg in "${CONFIGS[@]}"; do
    [[ -n "$(pdu_for "$cfg")" ]] || { echo "!! unknown config '$cfg' (use: default zcIO)"; exit 1; }
done

# Clear stale per-bs CSVs so a failed config can't reuse old numbers.
echo ">>> clearing stale CSVs: results-rocksdb-$BS-{${CONFIGS[*]// /,}}.csv"
for cfg in "${CONFIGS[@]}"; do
    rm -f "./results-rocksdb-$BS-$cfg.csv" "$ROCKSDB_DIR/results-rocksdb-$BS-$cfg.csv"
done

# ----- per-config single-block run ------------------------------------
for cfg in "${CONFIGS[@]}"; do
    PDU="$(pdu_for "$cfg")"; ZC="$(zc_for "$cfg")"; LABEL="$BS-$cfg"
    echo
    echo "############################################################"
    echo "# bs=$BS  config=$cfg   (ZCOPY=$ZC, nvme_pdu_align=$PDU)"
    echo "############################################################"

    echo ">>> [$cfg] disconnect existing NVMe/TCP sessions ..."
    ./disconnect.sh || echo "!! disconnect reported an error (continuing)"

    echo ">>> [$cfg] bringing up stack (setup.sh) ..."
    if ! NET_PDU="$PDU" ZCOPY="$ZC" ./setup.sh; then
        echo "!! setup failed for $cfg — skipping"; continue
    fi

    echo ">>> [$cfg] disks (mkfs+mount) + single-core RocksDB run (bs=$BS only) ..."
    if ! sudo bash -c "cd '$ROCKSDB_DIR' && (./unmount_4disk.sh >/dev/null 2>&1 || true) && ./mount_4disk.sh && ONLY_BS='$BS' ./rocksdb-run.sh '$LABEL'"; then
        echo "!! run failed for $cfg — continuing";
    fi
    if [[ -f "$ROCKSDB_DIR/results-rocksdb-$LABEL.csv" ]]; then
        cp "$ROCKSDB_DIR/results-rocksdb-$LABEL.csv" "./results-rocksdb-$LABEL.csv"
        echo "   -> ./results-rocksdb-$LABEL.csv"
    fi
done

# ----- compare --------------------------------------------------------
echo
echo "############################################################"
echo "# bs=$BS  default vs zcIO  (single-core readrand ops/s)"
echo "############################################################"
python3 - "$BS" "${CONFIGS[@]}" <<'PY'
import csv, os, sys
bs = sys.argv[1]; configs = sys.argv[2:]
def avg_row(cfg):
    p = f"results-rocksdb-{bs}-{cfg}.csv"
    if not os.path.exists(p): return None
    with open(p) as f:
        for row in csv.DictReader(f):
            if row.get("rep") == "avg" and row.get("bs") == bs:
                return row
    return None
rows = {c: avg_row(c) for c in configs}
print(f"{'config':<10}{'ops/s':<14}{'avg_us':<12}{'threads':<9}{'batch':<8}{'per_disk_file'}")
for c in configs:
    r = rows[c]
    if r: print(f"{c:<10}{r['ops_per_s']:<14}{r.get('avg_us',''):<12}{r['threads']:<9}{r.get('batch',''):<8}{r['per_disk_file']}")
    else: print(f"{c:<10}(no result)")
if rows.get("default") and rows.get("zcIO"):
    try:
        d = float(rows["default"]["ops_per_s"]); z = float(rows["zcIO"]["ops_per_s"])
        print(f"\nspeedup (zcIO/default) @ {bs}: {z/d:.2f}x   ({d:.0f} -> {z:.0f} ops/s)")
    except (ValueError, ZeroDivisionError): pass
PY

# ----- cleanup --------------------------------------------------------
echo
echo ">>> cleanup: unmount disks then nvme disconnect-all ..."
sudo bash -c "cd '$ROCKSDB_DIR' && ./unmount_4disk.sh" || echo "!! unmount reported an error (continuing)"
./disconnect.sh || echo "!! disconnect reported an error"

echo
echo "[compare-bs] done (bs=$BS). CSVs: results-rocksdb-$BS-{${CONFIGS[*]// /,}}.csv"
