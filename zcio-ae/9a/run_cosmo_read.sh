#!/usr/bin/env bash
set -e

source /opt/mlperf-env/venv/bin/activate

DATA_DIR="/mnt/rocksdb_test/mlperf_merged"
RESULTS_DIR="results_cosmoflow_accel5"
ACCELERATOR_TYPE="h100"
NUM_ACCELERATORS=5
NUM_FILES=8000
MEMORY_GB=40
COMPUTATION_TIME=0.00350
READ_THREADS=1
NUM_EPOCHS=1

export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OMPI_MCA_btl=^vader
export OMPI_MCA_hwloc_base_binding_policy=none
export OMPI_MCA_mpi_yield_when_idle=1
export OMPI_MCA_opal_progress_lp_call_yield=1

rm -rf "${RESULTS_DIR}"

mlpstorage training run \
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
