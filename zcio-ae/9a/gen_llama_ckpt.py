#!/usr/bin/env python3
# gen_llama_ckpt.py — rank-by-rank LLaMA3-8B checkpoint generator (bounded memory).
#
# The MLPerf/DLIO checkpointing generator builds all NRANKS shards CONCURRENTLY
# (8 ranks x ~13 GB ~= 105 GB resident) and OOMs on a 125 GB host. fig-9a only
# READS this checkpoint to measure NVMe/TCP read bandwidth, so the tensor CONTENT
# is irrelevant — we just need files of the right names/sizes that dio_bench can
# read. This writes them ONE shard at a time, so peak RAM = a single optim shard
# (~OPTIM_GB) instead of ~105 GB. Existing shards of the right size are skipped.
#
# Layout matches dio_bench (get_ckpt_subdir + the "pp_rank_{r}_" filter):
#   <CKPT_DIR>/pp_rank_{r}_model_states.pt   (~MODEL_GB each)
#   <CKPT_DIR>/pp_rank_{r}_optim_states.pt   (~OPTIM_GB each)
import os
import torch

GB = 1024 ** 3
CKPT_DIR = os.environ.get(
    "CKPT_DIR",
    "/mnt/rocksdb_test/testdb1/llama3_8b_ckpt/llama3-8b/global_epoch1_step1")
NRANKS   = int(os.environ.get("NRANKS", "8"))
MODEL_GB = float(os.environ.get("MODEL_GB", "1.9"))
OPTIM_GB = float(os.environ.get("OPTIM_GB", "11.2"))

os.makedirs(CKPT_DIR, exist_ok=True)


def write_shard(path, gb):
    want = int(gb * GB)
    if os.path.exists(path) and abs(os.path.getsize(path) - want) < 0.02 * want:
        print(f"  skip (exists): {os.path.basename(path)}", flush=True)
        return
    n = want // 4                                # float32 = 4 bytes/elem
    t = torch.empty(n, dtype=torch.float32)      # content irrelevant for the read bench
    torch.save({"a": t}, path)                   # dict -> dio_bench convert/_flatten_tensors works
    del t
    print(f"  wrote {gb:5.1f} GB  {os.path.basename(path)}", flush=True)


print(f"[gen_llama_ckpt] {NRANKS} ranks -> {CKPT_DIR}", flush=True)
print(f"[gen_llama_ckpt] peak RAM ~= {OPTIM_GB:.1f} GB (one shard at a time, NOT ~105 GB)",
      flush=True)
for r in range(NRANKS):
    write_shard(os.path.join(CKPT_DIR, f"pp_rank_{r}_model_states.pt"), MODEL_GB)
    write_shard(os.path.join(CKPT_DIR, f"pp_rank_{r}_optim_states.pt"), OPTIM_GB)

total = sum(os.path.getsize(os.path.join(CKPT_DIR, f))
            for f in os.listdir(CKPT_DIR) if f.endswith(".pt")) / GB
print(f"[gen_llama_ckpt] done. {2 * NRANKS} files, {total:.1f} GB on disk", flush=True)
