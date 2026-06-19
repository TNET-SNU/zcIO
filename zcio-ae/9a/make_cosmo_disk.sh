#!/usr/bin/env bash
# Generate CosmoFlow data + symlink-merge (full cores).
set -e

source /opt/mlperf-env/venv/bin/activate

# ── config ────────────────────────────────────────────────────────────────────
DATA_DIR="/mnt/rocksdb_test/mlperf_merged"
# Use only the 4 NVMe/TCP network disks. testdb5~8 are on the local root fs
# (/dev/mapper/ubuntu-vg); putting data there makes reads leak to local storage
# instead of the network, so the NIC throughput would only be half-measured.
DISK_ROOTS=(
    "/mnt/rocksdb_test/testdb1/cosmoflow_data"
    "/mnt/rocksdb_test/testdb2/cosmoflow_data"
    "/mnt/rocksdb_test/testdb3/cosmoflow_data"
    "/mnt/rocksdb_test/testdb4/cosmoflow_data"
)
NUM_DISKS=${#DISK_ROOTS[@]}
NUM_FILES=8000
FILES_PER_DISK=$((NUM_FILES / NUM_DISKS))   # 2000 per disk (8000/4)
NUM_PROCS=$(nproc)                           # full cores

echo "disks=${NUM_DISKS}, files_per_disk=${FILES_PER_DISK}, num_procs=${NUM_PROCS}"

# ── per-disk data generation ──────────────────────────────────────────────────
for i in "${!DISK_ROOTS[@]}"; do
    DISK_DIR="${DISK_ROOTS[$i]}"
    DISK_TRAIN="${DISK_DIR}/cosmoflow/train"
    DISK_COUNT=$(find "${DISK_TRAIN}" -maxdepth 1 -type f -name '*.npz' 2>/dev/null | wc -l)

    if [ "${DISK_COUNT}" -ge "${FILES_PER_DISK}" ]; then
        echo "  disk$((i+1)): ${DISK_COUNT} present, skip"
        continue
    fi

    echo "  disk$((i+1)): generating ${FILES_PER_DISK} files..."
    rm -rf "${DISK_TRAIN}"
    mlpstorage training datagen \
        --model cosmoflow \
        --num-processes ${NUM_PROCS} \
        --data-dir "${DISK_DIR}" \
        --results-dir "results_cosmoflow_datagen_disk$((i+1))" \
        --params dataset.num_files_train=${FILES_PER_DISK} \
                 framework=pytorch \
                 dataset.format=npz \
                 reader.data_loader=pytorch \
        --allow-run-as-root \
        --oversubscribe
    echo "  disk$((i+1)): done"
done

# ── symlink-merge ──────────────────────────────────────────────────────────────
MERGED_TRAIN="${DATA_DIR}/cosmoflow/train"

# Always rebuild: if DISK_ROOTS (disk layout) changes, an existing merge may hold
# stale symlinks pointing at the local disks (testdb5~8), so rebuild from scratch.
echo "rebuilding symlink-merge (${NUM_FILES} files, ${NUM_DISKS} disks interleaved)..."
rm -rf "${MERGED_TRAIN}"
mkdir -p "${MERGED_TRAIN}"

SRC_DIGITS=${#FILES_PER_DISK}
DST_DIGITS=${#NUM_FILES}
SRC_FMT="img_%0${SRC_DIGITS}d_of_${FILES_PER_DISK}.npz"
DST_FMT="img_%0${DST_DIGITS}d_of_${NUM_FILES}.npz"

for i in $(seq 0 $((FILES_PER_DISK - 1))); do
    for disk_idx in $(seq 1 ${NUM_DISKS}); do
        merged_idx=$(( i * NUM_DISKS + disk_idx - 1 ))
        src_name=$(printf "${SRC_FMT}" $i)
        dst_name=$(printf "${DST_FMT}" $merged_idx)
        DISK_DIR="${DISK_ROOTS[$((disk_idx - 1))]}"
        ln -s "${DISK_DIR}/cosmoflow/train/${src_name}" \
              "${MERGED_TRAIN}/${dst_name}"
    done
done

echo "symlink-merge done: $(ls "${MERGED_TRAIN}" | wc -l) files"
