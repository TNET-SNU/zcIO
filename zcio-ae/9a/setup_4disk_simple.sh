#!/usr/bin/env bash
# Prepare the 4-disk NVMe-oF/TCP dataset (matches run_unet3d_simple.sh).
# - 3168 files = 792/disk × 4 disks (6 accel × 4 threads = 24, evenly sharded)
# - if data already exists, skip datagen and only rebuild the symlinks
set -e

source /opt/mlperf-env/venv/bin/activate

MERGED="/mnt/rocksdb_test/mlperf_merged"
FILES_PER_DISK=800          # 800 × 4 = 3200 (matches num_files_train=3200 in run_unet3d_*.sh)
TOTAL=$((FILES_PER_DISK * 4))

cd "$(dirname "$0")/.."

# ── Step 1: datagen (only disks short on files) ─────────────────────────────
for i in 1 2 3 4; do
    DISK_DIR="/mnt/rocksdb_test/testdb${i}/mlperf_data"
    TRAIN_DIR="${DISK_DIR}/unet3d/train"
    COUNT=$(ls "${TRAIN_DIR}" 2>/dev/null | wc -l || echo 0)
    if [ "$COUNT" -ge "$FILES_PER_DISK" ]; then
        echo "disk${i}: ${COUNT} files present → skipping datagen"
        continue
    fi
    echo "── disk${i}: generating ${FILES_PER_DISK} files ──"
    mlpstorage training datagen \
        --model unet3d \
        --num-processes 4 \
        --data-dir "${DISK_DIR}" \
        --results-dir "results_datagen" \
        --params dataset.num_files_train=${FILES_PER_DISK} \
        --allow-run-as-root \
        --oversubscribe
done

# ── Step 2: rebuild the symlink merge directory ─────────────────────────────
# The file name format is taken from the actual file names datagen produced.
MERGED_TRAIN="${MERGED}/unet3d/train"
echo "── rebuilding merge dir: ${MERGED_TRAIN} (${TOTAL} files, interleaved) ──"
# Do NOT remove the merge dir itself (parent /mnt/rocksdb_test is owned by ki, so
# rm -rf "${MERGED}" is Permission denied). Only empty and rebuild its contents.
mkdir -p "${MERGED}"
rm -rf "${MERGED:?}/unet3d"
mkdir -p "${MERGED_TRAIN}"

# Read each disk's sorted train file list once (avoids O(n^2) ls calls).
declare -a DISK_FILES_1 DISK_FILES_2 DISK_FILES_3 DISK_FILES_4
for disk_idx in 1 2 3 4; do
    DISK_TRAIN="/mnt/rocksdb_test/testdb${disk_idx}/mlperf_data/unet3d/train"
    mapfile -t "DISK_FILES_${disk_idx}" < <(ls "${DISK_TRAIN}" | sort)
    eval "cnt=\${#DISK_FILES_${disk_idx}[@]}"
    if [ "$cnt" -lt "$FILES_PER_DISK" ]; then
        echo "ERROR: disk${disk_idx} file count (${cnt}) < ${FILES_PER_DISK}"
        exit 1
    fi
done

for i in $(seq 0 $((FILES_PER_DISK - 1))); do
    for disk_idx in 1 2 3 4; do
        merged_idx=$(( i * 4 + disk_idx - 1 ))
        DISK_TRAIN="/mnt/rocksdb_test/testdb${disk_idx}/mlperf_data/unet3d/train"
        # use the actual file name as-is (the of_N part varies with datagen params)
        eval "src_file=\${DISK_FILES_${disk_idx}[$i]}"
        dst_name=$(printf "img_%04d_of_%d.npz" $merged_idx $TOTAL)
        ln -s "${DISK_TRAIN}/${src_file}" "${MERGED_TRAIN}/${dst_name}"
    done
done

echo ""
echo "Done. total symlinks: $(ls ${MERGED_TRAIN} | wc -l)"
echo "DATA_DIR=${MERGED}  NUM_FILES=${TOTAL}"
echo ""
echo "Next: ./test/run_unet3d_simple.sh"
