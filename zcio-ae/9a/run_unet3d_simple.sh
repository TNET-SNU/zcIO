#!/usr/bin/env bash
# UNet3D 단순 실행 스크립트 (taskset 없음, 정리 없음)
# 사용법: 실험 전에 setup_irq.sh 먼저 실행, CPU offline/online은 직접 조절
set -e

source /opt/mlperf-env/venv/bin/activate

export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

export OMPI_MCA_btl=^vader
export OMPI_MCA_hwloc_base_binding_policy=none
export OMPI_MCA_mpi_yield_when_idle=1
export OMPI_MCA_opal_progress_lp_call_yield=1

DATA_DIR="/mnt/rocksdb_test/mlperf_merged"
ACCELERATOR_TYPE="h100"
NUM_ACCELERATORS=2
NUM_FILES=3072           # 8×12×33 = 3168 (num_accel × read_threads로 균등 분배)
READ_THREADS=8
MEMORY_GB=$((6 * NUM_ACCELERATORS))  # 36 GB

RESULTS_DIR="results_6gpu_$(date +%Y%m%d_%H%M%S)"

cd "$(dirname "$0")/.."

echo "online CPUs: $(cat /sys/devices/system/cpu/online)"
echo "NUM_ACCELERATORS=${NUM_ACCELERATORS}, NUM_FILES=${NUM_FILES}, READ_THREADS=${READ_THREADS}"
echo "RESULTS_DIR=${RESULTS_DIR}"
echo ""

mlpstorage training run \
    --model unet3d \
    --accelerator-type ${ACCELERATOR_TYPE} \
    --num-accelerators ${NUM_ACCELERATORS} \
    --client-host-memory-in-gb ${MEMORY_GB} \
    --data-dir ${DATA_DIR} \
    --results-dir ${RESULTS_DIR} \
    --params dataset.num_files_train=${NUM_FILES} \
             reader.odirect=true \
             reader.read_threads=${READ_THREADS} \
             train.epochs=1 \
    --open \
    --allow-run-as-root \
    --oversubscribe

LATEST_RUN=$(ls -td ${RESULTS_DIR}/training/unet3d/run/*/ 2>/dev/null | head -1)
AU=$(grep -rh "train_au_mean_percentage" "${LATEST_RUN}" 2>/dev/null \
     | grep -oP '[0-9]+\.[0-9]+' | head -1)
PASS=$(grep -rh "train_au_meet_expectation" "${LATEST_RUN}" 2>/dev/null \
       | grep -oP '(success|fail)' | head -1)

echo ""
echo "AU=${AU:-N/A}%  [${PASS:-N/A}]"
