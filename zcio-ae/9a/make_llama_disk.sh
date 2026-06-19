#!/usr/bin/env bash
# Write the LLaMA3-8B checkpoint to disk (write only).
set -e

source /opt/mlperf-env/venv/bin/activate

# ── config ────────────────────────────────────────────────────────────────────
CHECKPOINT_DIR="/mnt/rocksdb_test/testdb1/llama3_8b_ckpt"
MODEL="llama3-8b"
NUM_PROCESSES=8
MEMORY_GB=118
NUM_CHECKPOINTS_WRITE=1
RESULTS_DIR="results_llama_write"

export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMPI_MCA_btl=^vader
export OMPI_MCA_hwloc_base_binding_policy=none

mkdir -p "${CHECKPOINT_DIR}"
echo "checkpoint dir: ${CHECKPOINT_DIR}"
echo "disk available: $(df -h "${CHECKPOINT_DIR}" | tail -1 | awk '{print $4}')"

rm -rf "${RESULTS_DIR}"

mlpstorage checkpointing run \
    --hosts 127.0.0.1 \
    --model ${MODEL} \
    --client-host-memory-in-gb ${MEMORY_GB} \
    --num-processes ${NUM_PROCESSES} \
    --checkpoint-folder ${CHECKPOINT_DIR} \
    --results-dir ${RESULTS_DIR} \
    --num-checkpoints-write ${NUM_CHECKPOINTS_WRITE} \
    --num-checkpoints-read 0 \
    --open \
    --allow-run-as-root \
    --oversubscribe

echo "Done. file count: $(find "${CHECKPOINT_DIR}" -type f | wc -l)"
du -sh "${CHECKPOINT_DIR}"
