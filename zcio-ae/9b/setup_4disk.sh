#!/usr/bin/env bash
# Setup 4-disk NVMe-oF/TCP dataset for MLPerf UNet3D benchmark.
# Strategy: generate 875 files per disk, then symlink-merge into one
# directory presenting 3500 files (interleaved across disks).
# ~511 GB per epoch (~500 GB target).

set -e
source /opt/mlperf-env/venv/bin/activate

# Run: sudo chown jonghyeon /mnt/rocksdb_test/testdb{1,2,3,4}  if permission denied below.

DISK1="/mnt/rocksdb_test/testdb1/mlperf_data"
DISK2="/mnt/rocksdb_test/testdb2/mlperf_data"
DISK3="/mnt/rocksdb_test/testdb3/mlperf_data"
DISK4="/mnt/rocksdb_test/testdb4/mlperf_data"
MERGED="/mnt/rocksdb_test/mlperf_merged"
RESULTS_DIR="results_unet3d"
NUM_FILES=800  # files per disk → 3500 total, ~511 GB/epoch

cd "$(dirname "$0")/.."

# ── Step 1: Generate data on all 4 disks (skip if already complete) ──────────

for i in 1 2 3 4; do
    DISK_DIR="/mnt/rocksdb_test/testdb${i}/mlperf_data"
    TRAIN_DIR="${DISK_DIR}/unet3d/train"
    COUNT=$(ls "${TRAIN_DIR}" 2>/dev/null | wc -l || echo 0)
    if [ "$COUNT" -eq "$NUM_FILES" ]; then
        echo "disk${i}: ${NUM_FILES} files already exist, skipping datagen."
        continue
    fi
    echo "── Generating ${NUM_FILES} files on disk${i} ──"
    mlpstorage training datagen \
        --model unet3d \
        --num-processes 28 \
        --data-dir "${DISK_DIR}" \
        --results-dir "${RESULTS_DIR}" \
        --params dataset.num_files_train=${NUM_FILES} \
        --allow-run-as-root \
        --oversubscribe
done

# ── Step 2: Build symlink-merged directory ────────────────────────────────────
# Layout: MERGED/unet3d/train/ contains 4000 symlinks, interleaved across disks.
#
# Interleaved naming (not contiguous blocks):
#   img_000 → disk1/file_000,  img_001 → disk2/file_000
#   img_002 → disk3/file_000,  img_003 → disk4/file_000
#   img_004 → disk1/file_001,  img_005 → disk2/file_001, ...
#
# Why: DLIO's PyTorch DataLoader uses dlio_sampler which yields indices
# 0,1,2,...,671 in sequential order (file_shuffle is not applied in the
# INDEX sampler path). With contiguous blocks, this means all reads go to
# disk1 first, then disk2, etc. — sequential, not parallel.
# With interleaved naming every 4 consecutive indices hit all 4 disks,
# guaranteeing parallel I/O from the very first step.

TOTAL=$((NUM_FILES * 4))
MERGED_TRAIN="${MERGED}/unet3d/train"

echo "── Building merged directory: ${MERGED_TRAIN} (${TOTAL} files, interleaved) ──"
# /mnt/rocksdb_test is owned by another user (ki), so the top dir (${MERGED}) cannot be removed.
# Only empty and rebuild the train subdir (the parent mlperf_merged/unet3d is ours).
rm -rf "${MERGED_TRAIN}"
mkdir -p "${MERGED_TRAIN}"

for i in $(seq 0 $((NUM_FILES - 1))); do
    for disk_idx in 1 2 3 4; do
        merged_idx=$(( i * 4 + disk_idx - 1 ))
        src_name=$(printf "img_%03d_of_%d.npz" $i $NUM_FILES)
        dst_name=$(printf "img_%03d_of_%d.npz" $merged_idx $TOTAL)
        DISK_DIR="/mnt/rocksdb_test/testdb${disk_idx}/mlperf_data"
        ln -s "${DISK_DIR}/unet3d/train/${src_name}" "${MERGED_TRAIN}/${dst_name}"
    done
done
echo "  Interleaved: img_{0,1,2,3}→disk{1,2,3,4} file_0, img_{4,5,6,7}→disk{1,2,3,4} file_1, ..."

echo ""
echo "Done. Merged dataset: ${MERGED_TRAIN}"
echo "Total symlinks: $(ls ${MERGED_TRAIN} | wc -l)"
echo ""
echo "Next: run the benchmark with:"
echo "  DATA_DIR=${MERGED}  NUM_FILES=${TOTAL}"
