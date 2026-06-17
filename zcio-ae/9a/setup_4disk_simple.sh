#!/usr/bin/env bash
# 4-disk NVMe-oF/TCP 데이터셋 준비 (run_unet3d_simple.sh 대응)
# - 3168 파일 = 792/디스크 × 4디스크 (6 accel × 4 threads = 24로 균등 분배)
# - 이미 데이터가 있으면 datagen 생략, symlink만 재구성
set -e

source /opt/mlperf-env/venv/bin/activate

MERGED="/mnt/rocksdb_test/mlperf_merged"
FILES_PER_DISK=800          # 800 × 4 = 3200 (run_unet3d_*.sh 의 num_files_train=3200 과 일치)
TOTAL=$((FILES_PER_DISK * 4))

cd "$(dirname "$0")/.."

# ── Step 1: datagen (파일 수가 부족한 디스크만) ─────────────────────────────
for i in 1 2 3 4; do
    DISK_DIR="/mnt/rocksdb_test/testdb${i}/mlperf_data"
    TRAIN_DIR="${DISK_DIR}/unet3d/train"
    COUNT=$(ls "${TRAIN_DIR}" 2>/dev/null | wc -l || echo 0)
    if [ "$COUNT" -ge "$FILES_PER_DISK" ]; then
        echo "disk${i}: ${COUNT}개 파일 존재 → datagen 생략"
        continue
    fi
    echo "── disk${i}: ${FILES_PER_DISK}개 생성 중 ──"
    mlpstorage training datagen \
        --model unet3d \
        --num-processes 4 \
        --data-dir "${DISK_DIR}" \
        --results-dir "results_datagen" \
        --params dataset.num_files_train=${FILES_PER_DISK} \
        --allow-run-as-root \
        --oversubscribe
done

# ── Step 2: symlink 머지 디렉토리 재구성 ────────────────────────────────────
# 파일 이름 형식은 datagen이 생성한 실제 파일명에서 추출
MERGED_TRAIN="${MERGED}/unet3d/train"
echo "── 머지 디렉토리 재구성: ${MERGED_TRAIN} (${TOTAL}개, 인터리브) ──"
# 머지 디렉토리 자체는 지우지 않는다 (부모 /mnt/rocksdb_test 가 ki 소유라
# rm -rf "${MERGED}" 는 Permission denied). 내용물만 비우고 재구성한다.
mkdir -p "${MERGED}"
rm -rf "${MERGED:?}/unet3d"
mkdir -p "${MERGED_TRAIN}"

# 각 디스크의 train 파일 목록을 정렬해 한 번만 읽어둔다 (O(n²) ls 호출 방지).
declare -a DISK_FILES_1 DISK_FILES_2 DISK_FILES_3 DISK_FILES_4
for disk_idx in 1 2 3 4; do
    DISK_TRAIN="/mnt/rocksdb_test/testdb${disk_idx}/mlperf_data/unet3d/train"
    mapfile -t "DISK_FILES_${disk_idx}" < <(ls "${DISK_TRAIN}" | sort)
    eval "cnt=\${#DISK_FILES_${disk_idx}[@]}"
    if [ "$cnt" -lt "$FILES_PER_DISK" ]; then
        echo "ERROR: disk${disk_idx} 파일 수(${cnt}) < ${FILES_PER_DISK}"
        exit 1
    fi
done

for i in $(seq 0 $((FILES_PER_DISK - 1))); do
    for disk_idx in 1 2 3 4; do
        merged_idx=$(( i * 4 + disk_idx - 1 ))
        DISK_TRAIN="/mnt/rocksdb_test/testdb${disk_idx}/mlperf_data/unet3d/train"
        # 실제 파일명 그대로 사용 (of_N 부분이 datagen 파라미터에 따라 달라짐)
        eval "src_file=\${DISK_FILES_${disk_idx}[$i]}"
        dst_name=$(printf "img_%04d_of_%d.npz" $merged_idx $TOTAL)
        ln -s "${DISK_TRAIN}/${src_file}" "${MERGED_TRAIN}/${dst_name}"
    done
done

echo ""
echo "완료. 총 심링크: $(ls ${MERGED_TRAIN} | wc -l)"
echo "DATA_DIR=${MERGED}  NUM_FILES=${TOTAL}"
echo ""
echo "다음: ./test/run_unet3d_simple.sh"
