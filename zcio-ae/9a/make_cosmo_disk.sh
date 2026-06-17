#!/usr/bin/env bash
# CosmoFlow 데이터 생성 + symlink-merge (풀코어)
set -e

source /opt/mlperf-env/venv/bin/activate

# ── 설정 ──────────────────────────────────────────────────────────────────────
DATA_DIR="/mnt/rocksdb_test/mlperf_merged"
# NVMe/TCP 네트워크 디스크 4장만 사용. testdb5~8은 로컬 루트fs(/dev/mapper/ubuntu-vg)라
# 거기 데이터를 깔면 read가 네트워크가 아니라 로컬로 새서 NIC throughput이 반쪽만 잡힌다.
DISK_ROOTS=(
    "/mnt/rocksdb_test/testdb1/cosmoflow_data"
    "/mnt/rocksdb_test/testdb2/cosmoflow_data"
    "/mnt/rocksdb_test/testdb3/cosmoflow_data"
    "/mnt/rocksdb_test/testdb4/cosmoflow_data"
)
NUM_DISKS=${#DISK_ROOTS[@]}
NUM_FILES=8000
FILES_PER_DISK=$((NUM_FILES / NUM_DISKS))   # 2000 per disk (8000/4)
NUM_PROCS=$(nproc)                           # 풀코어

echo "disks=${NUM_DISKS}, files_per_disk=${FILES_PER_DISK}, num_procs=${NUM_PROCS}"

# ── 디스크별 데이터 생성 ───────────────────────────────────────────────────────
for i in "${!DISK_ROOTS[@]}"; do
    DISK_DIR="${DISK_ROOTS[$i]}"
    DISK_TRAIN="${DISK_DIR}/cosmoflow/train"
    DISK_COUNT=$(find "${DISK_TRAIN}" -maxdepth 1 -type f -name '*.npz' 2>/dev/null | wc -l)

    if [ "${DISK_COUNT}" -ge "${FILES_PER_DISK}" ]; then
        echo "  disk$((i+1)): ${DISK_COUNT}개 존재, skip"
        continue
    fi

    echo "  disk$((i+1)): ${FILES_PER_DISK}개 생성 중..."
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
    echo "  disk$((i+1)): 완료"
done

# ── symlink-merge ──────────────────────────────────────────────────────────────
MERGED_TRAIN="${DATA_DIR}/cosmoflow/train"

# 항상 재생성: DISK_ROOTS(디스크 구성)가 바뀌면 기존 merge가 로컬 디스크(testdb5~8)를
# 가리키는 stale 심링크일 수 있으므로 재사용하지 않고 매번 새로 만든다.
echo "symlink-merge 재생성 중 (${NUM_FILES}개, ${NUM_DISKS}장 인터리브)..."
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

echo "symlink-merge 완료: $(ls "${MERGED_TRAIN}" | wc -l)개"
