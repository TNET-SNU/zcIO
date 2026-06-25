#!/usr/bin/env bash
# Write the LLaMA3-8B checkpoint to disk (write only) — rank-by-rank, bounded memory.
#
# The MLPerf/DLIO checkpointing generator builds all 8 rank shards CONCURRENTLY
# (~105 GB resident) and OOMs on a 125 GB host. fig-9a only READS this checkpoint
# to measure NVMe/TCP read bandwidth, so the content is irrelevant; gen_llama_ckpt.py
# writes the same on-disk shape ONE shard at a time (peak ~= one ~11.2 GB optim
# shard). Existing shards of the right size are skipped, so reruns are cheap.
set -e

source /opt/mlperf-env/venv/bin/activate
cd "$(dirname "$(readlink -f "$0")")"

# ── config ────────────────────────────────────────────────────────────────────
CHECKPOINT_DIR="/mnt/rocksdb_test/testdb1/llama3_8b_ckpt"
STEP="${STEP:-global_epoch1_step1}"                 # must match dio_bench --step default
CKPT_DIR="${CHECKPOINT_DIR}/llama3-8b/${STEP}"      # = dio_bench get_ckpt_subdir() path
NRANKS="${NRANKS:-8}"                               # dio_bench reads 8 ranks over 4 disks
MODEL_GB="${MODEL_GB:-1.9}"
OPTIM_GB="${OPTIM_GB:-11.2}"

mkdir -p "${CKPT_DIR}"
echo "checkpoint dir: ${CKPT_DIR}"
echo "disk available: $(df -h "${CHECKPOINT_DIR}" | tail -1 | awk '{print $4}')"

# rank-by-rank generation: peak ~= one optim shard (~11.2 GB), NOT ~105 GB.
CKPT_DIR="${CKPT_DIR}" NRANKS="${NRANKS}" MODEL_GB="${MODEL_GB}" OPTIM_GB="${OPTIM_GB}" \
    python3 ./gen_llama_ckpt.py

echo "Done. file count: $(find "${CHECKPOINT_DIR}" -type f | wc -l)"
du -sh "${CHECKPOINT_DIR}"
