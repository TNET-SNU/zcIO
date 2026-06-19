#!/usr/bin/env bash
# Run the CosmoFlow benchmark (single core, minimal overhead).
set -e

source /opt/mlperf-env/venv/bin/activate

# ── config ────────────────────────────────────────────────────────────────────
DATA_DIR="/mnt/rocksdb_test/mlperf_merged"
RESULTS_DIR="results_cosmoflow_single"
ACCELERATOR_TYPE="h100"
NUM_ACCELERATORS=5
NUM_FILES=8000
MEMORY_GB=40
COMPUTATION_TIME=0.00350
READ_THREADS=5
NUM_EPOCHS=1
CPU_CORE=0   # taskset -c 0 (single core)

export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1

export OMPI_MCA_btl=^vader
export OMPI_MCA_hwloc_base_binding_policy=none

rm -rf "${RESULTS_DIR}"

taskset -c ${CPU_CORE} mlpstorage training run \
    --model cosmoflow \
    --accelerator-type ${ACCELERATOR_TYPE} \
    --num-accelerators ${NUM_ACCELERATORS} \
    --client-host-memory-in-gb ${MEMORY_GB} \
    --data-dir ${DATA_DIR} \
    --results-dir ${RESULTS_DIR} \
    --params dataset.num_files_train=${NUM_FILES} \
             train.computation_time=${COMPUTATION_TIME} \
             train.epochs=${NUM_EPOCHS} \
             reader.odirect=true \
             reader.read_threads=${READ_THREADS} \
             framework=pytorch \
             dataset.format=npz \
             reader.data_loader=pytorch \
             dataset.record_length_bytes_resize=262144 \
    --open \
    --allow-invalid-params \
    --allow-run-as-root \
    --oversubscribe
