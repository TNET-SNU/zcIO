#!/usr/bin/env python3
"""
LLaMA3-8B Checkpoint Direct I/O Read Benchmark  (4-disk parallel)

Reads the real LLaMA3-8B checkpoint .pt files produced by mlpstorage in parallel
across 8 disks via O_DIRECT and measures throughput.

Checkpoint layout (1 step):
  8 rank × (model_states ~1.9GB + optim_states ~11.2GB) ≈ 105 GB
  → 8 disks × 1 rank = 2 files/disk

Usage:
  python3 dio_bench.py convert                            # .pt → .safetensors convert (testdb1)
  python3 dio_bench.py distribute                         # distribute files across 8 disks
  python3 dio_bench.py run                                # parallel raw read on 8 disks (default)
  python3 dio_bench.py run --mode safetensors             # safetensors O_DIRECT (I/O bound)
  python3 dio_bench.py run --mode torch                   # parallel torch.load on 8 disks
  python3 dio_bench.py run --disks 1                      # use a single disk only
  python3 dio_bench.py run --read-cores 1                 # core limit
  python3 dio_bench.py run --repeats 5
"""

import os
import sys
import mmap
import json
import struct
import time
import shutil
import argparse
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

# safetensors dtype string → torch dtype mapping
SAFETENSORS_DTYPE = {
    "F64":  "torch.float64",
    "F32":  "torch.float32",
    "F16":  "torch.float16",
    "BF16": "torch.bfloat16",
    "I64":  "torch.int64",
    "I32":  "torch.int32",
    "I16":  "torch.int16",
    "I8":   "torch.int8",
    "U8":   "torch.uint8",
    "BOOL": "torch.bool",
}

# Limit concurrent torch.load calls (memory protection).
# torch.load uses ~3x the file size in temporary memory during deserialization.
# 11.2 GB × 3 = ~33 GB/slot. Semaphore(2) → 66 GB + 44 GB buffers = ~110 GB → safe under 125 GB.
_torch_sem = threading.Semaphore(2)

ALIGNMENT = 4096
DEFAULT_CHUNK = 1280 * 1024  # 1280 KB

DISK_ROOTS = [
    "/mnt/rocksdb_test/testdb1",
    "/mnt/rocksdb_test/testdb2",
    "/mnt/rocksdb_test/testdb3",
    "/mnt/rocksdb_test/testdb4",
#    "/mnt/rocksdb_test/testdb5",
#    "/mnt/rocksdb_test/testdb6",
#    "/mnt/rocksdb_test/testdb7",
#    "/mnt/rocksdb_itest/testdb8",
]

# rank → disk mapping: rank 0 → disk0, rank 1 → disk1, ...
RANKS_PER_DISK = 2


def drop_caches():
    os.system("sync")


GB = 1024 ** 3


# ───────────────────── distribute subcommand ─────────────────────

def get_ckpt_subdir(step):
    return os.path.join("llama3_8b_ckpt", "llama3-8b", step)


def cmd_distribute(args):
    """Distribute the testdb1 checkpoint across 8 disks by rank.
    Copies both the .pt and .safetensors files."""
    src_dir = os.path.join(DISK_ROOTS[0], get_ckpt_subdir(args.step))
    if not os.path.isdir(src_dir):
        print(f"ERROR: {src_dir} not found"); sys.exit(1)

    all_ckpt = sorted(f for f in os.listdir(src_dir)
                      if f.endswith('.pt') or f.endswith('.safetensors'))
    print(f"  Source : {src_dir}")
    print(f"  Files  : {len(all_ckpt)}")
    print(f"  Disks  : {len(DISK_ROOTS)}")
    print(f"  Layout : {RANKS_PER_DISK} ranks/disk\n")

    for rank in range(8):
        disk_idx = rank // RANKS_PER_DISK
        dst_dir = os.path.join(DISK_ROOTS[disk_idx], get_ckpt_subdir(args.step))
        os.makedirs(dst_dir, exist_ok=True)

        rank_files = [f for f in all_ckpt if f"pp_rank_{rank}_" in f]
        for fname in rank_files:
            src = os.path.join(src_dir, fname)
            dst = os.path.join(dst_dir, fname)
            sz = os.path.getsize(src) / GB
            if os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src):
                print(f"  [disk{disk_idx+1}] {fname} ({sz:.1f} GB) — skip")
                continue
            print(f"  [disk{disk_idx+1}] {fname} ({sz:.1f} GB) — copying...",
                  end=" ", flush=True)
            t0 = time.monotonic()
            shutil.copy2(src, dst)
            t1 = time.monotonic()
            print(f"done ({t1-t0:.1f}s, {sz/(t1-t0):.2f} GB/s)")

    print("\n  distribution done!")
    for i, root in enumerate(DISK_ROOTS):
        d = os.path.join(root, get_ckpt_subdir(args.step))
        if os.path.isdir(d):
            files = [f for f in os.listdir(d)
                     if f.endswith('.pt') or f.endswith('.safetensors')]
            total = sum(os.path.getsize(os.path.join(d, f)) for f in files)
            print(f"  disk{i+1}: {len(files)} files, {total/GB:.1f} GB")


def _flatten_tensors(obj, prefix=''):
    """Flatten only the tensors out of a nested state dict. safetensors supports only a flat tensor dict."""
    import torch
    out = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.update(_flatten_tensors(v, f"{prefix}{k}."))
    elif isinstance(obj, (list, tuple)):
        for i, v in enumerate(obj):
            out.update(_flatten_tensors(v, f"{prefix}{i}."))
    elif isinstance(obj, torch.Tensor):
        out[prefix.rstrip('.')] = obj.contiguous()
    return out


def cmd_convert(args):
    """Convert the testdb1 .pt checkpoint to .safetensors.
    Run before distribute. The original .pt is kept."""
    import torch
    try:
        from safetensors.torch import save_file
    except ImportError:
        print("ERROR: safetensors not installed.  pip install safetensors")
        sys.exit(1)

    src_dir = os.path.join(DISK_ROOTS[0], get_ckpt_subdir(args.step))
    pt_files = sorted(f for f in os.listdir(src_dir) if f.endswith('.pt'))
    if not pt_files:
        print(f"ERROR: no .pt files in {src_dir}"); sys.exit(1)

    print(f"  Converting {len(pt_files)} files in {src_dir}")
    for fname in pt_files:
        src = os.path.join(src_dir, fname)
        dst = src[:-3] + '.safetensors'
        sz = os.path.getsize(src) / GB
        if os.path.exists(dst) and os.path.getsize(dst) > 0:
            print(f"  skip: {fname} → already converted ({os.path.getsize(dst)/GB:.1f} GB)")
            continue
        print(f"  {fname} ({sz:.1f} GB) → .safetensors ...", end=' ', flush=True)
        t0 = time.monotonic()
        state = torch.load(src, weights_only=False)
        flat = _flatten_tensors(state)
        save_file(flat, dst)
        del state, flat
        t1 = time.monotonic()
        print(f"done ({t1-t0:.1f}s → {os.path.getsize(dst)/GB:.1f} GB)")
    print("  conversion done! Run 'distribute' again.")


# ───────────────────── I/O functions ─────────────────────

def dio_raw_read_files(file_list, chunk_size):
    """O_DIRECT raw read — one thread reads the files in file_list sequentially.
    Returns (total_bytes, io_seconds)."""
    buf = mmap.mmap(-1, chunk_size)
    mv = memoryview(buf)
    total_bytes = 0
    t0 = time.monotonic()
    for path in file_list:
        file_size = os.path.getsize(path)
        read_size = ((file_size + ALIGNMENT - 1) // ALIGNMENT) * ALIGNMENT
        fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
        try:
            done = 0
            while done < read_size:
                want = min(chunk_size, read_size - done)
                n = os.readv(fd, [mv[0:want]])
                if n == 0:
                    break
                done += n
        finally:
            os.close(fd)
        total_bytes += file_size
    t1 = time.monotonic()
    mv.release()
    buf.close()
    return total_bytes, t1 - t0


class SizedMmap:
    """mmap wrapper with bounded size for torch.load()."""
    __slots__ = ('_mm', '_size')

    def __init__(self, mm, real_size):
        self._mm = mm
        self._size = real_size
        mm.seek(0)

    def readable(self):  return True
    def writable(self):  return False
    def seekable(self):  return True
    def tell(self):      return self._mm.tell()

    def seek(self, offset, whence=0):
        if whence == 0:   pos = offset
        elif whence == 1: pos = self._mm.tell() + offset
        elif whence == 2: pos = self._size + offset
        else: raise ValueError(f"invalid whence {whence}")
        pos = max(0, min(pos, self._size))
        self._mm.seek(pos)
        return pos

    def read(self, n=-1):
        pos = self._mm.tell()
        if n is None or n < 0: n = self._size - pos
        n = min(n, self._size - pos)
        if n <= 0: return b''
        return self._mm.read(n)

    def readline(self):
        pos = self._mm.tell()
        if pos >= self._size: return b''
        line = self._mm.readline()
        new_pos = self._mm.tell()
        if new_pos > self._size:
            overshoot = new_pos - self._size
            self._mm.seek(self._size)
            return line[:-overshoot] if overshoot <= len(line) else b''
        return line


def dio_torch_load_files(file_list, io_buf, chunk_size):
    """O_DIRECT prefetch into pre-allocated buffer → torch.load.
    One thread processes file_list sequentially.
    Returns (total_bytes, io_seconds_sum)."""
    import torch
    mv = memoryview(io_buf)
    total_bytes = 0
    io_sec_sum = 0.0

    for path in file_list:
        file_size = os.path.getsize(path)
        read_size = ((file_size + ALIGNMENT - 1) // ALIGNMENT) * ALIGNMENT

        # Phase 1: O_DIRECT bulk read
        t0 = time.monotonic()
        fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
        try:
            done = 0
            while done < read_size:
                want = min(chunk_size, read_size - done)
                n = os.readv(fd, [mv[done:done + want]])
                if n == 0: break
                done += n
        finally:
            os.close(fd)
        t1 = time.monotonic()
        io_sec_sum += (t1 - t0)

        # Phase 2: torch.load — limit concurrency with a semaphore (avoid OOM)
        with _torch_sem:
            state = torch.load(SizedMmap(io_buf, file_size), weights_only=False)
            del state
        total_bytes += file_size

    mv.release()
    return total_bytes, io_sec_sum


def dio_safetensors_load_files(file_list, io_buf, chunk_size):
    """O_DIRECT read .safetensors → parse header → torch.frombuffer() (zero-copy).
    Deserialization overhead ≈ 0 → I/O is the bottleneck.
    Returns (total_bytes, io_seconds_sum)."""
    import torch
    mv = memoryview(io_buf)
    total_bytes = 0
    io_sec_sum = 0.0

    for path in file_list:
        file_size = os.path.getsize(path)
        read_size = ((file_size + ALIGNMENT - 1) // ALIGNMENT) * ALIGNMENT

        # O_DIRECT bulk read
        t0 = time.monotonic()
        fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
        try:
            done = 0
            while done < read_size:
                want = min(chunk_size, read_size - done)
                n = os.readv(fd, [mv[done:done + want]])
                if n == 0:
                    break
                done += n
        finally:
            os.close(fd)
        t1 = time.monotonic()
        io_sec_sum += (t1 - t0)

        # parse safetensors header (in-memory, no I/O)
        header_len = struct.unpack_from('<Q', io_buf, 0)[0]
        header = json.loads(bytes(mv[8:8 + header_len]))
        data_base = 8 + header_len

        # build tensors: reference the mmap buffer directly (zero-copy)
        tensors = {}
        for name, meta in header.items():
            if name == '__metadata__':
                continue
            dtype_str = meta['dtype']
            dtype = getattr(torch, SAFETENSORS_DTYPE[dtype_str].split('.')[1])
            shape = meta['shape']
            start, end = meta['data_offsets']
            tensors[name] = torch.frombuffer(
                mv[data_base + start:data_base + end], dtype=dtype
            ).reshape(shape)
        del tensors
        total_bytes += file_size

    mv.release()
    return total_bytes, io_sec_sum


# ───────────────────── run subcommand ─────────────────────

def collect_disk_files(num_disks, step, ranks, ext='.pt'):
    """Return the file list per disk, including only the ranks assigned to each disk.
    num_disks==1 (single disk mode): read all rank files from testdb1
      (before distribute, the original holds them all on testdb1).
    Returns: list of (disk_idx, [file_paths]), total_size"""
    disk_files = []
    total_size = 0

    for disk_idx in range(num_disks):
        root = DISK_ROOTS[disk_idx]
        step_dir = os.path.join(root, get_ckpt_subdir(step))
        if not os.path.isdir(step_dir):
            print(f"  WARNING: {step_dir} not found — run distribute first")
            continue

        all_files = sorted(os.path.join(step_dir, f)
                           for f in os.listdir(step_dir)
                           if f.endswith(ext))

        if num_disks == 1:
            # Single disk mode: read all rank files from one disk
            # testdb1 holds the pre-distribute original, so all rank files are reachable
            files = all_files
        else:
            # Multi disk mode: filter to only the ranks assigned to this disk
            start_rank = disk_idx * RANKS_PER_DISK
            end_rank = min(start_rank + RANKS_PER_DISK, ranks)
            filtered = []
            for r in range(start_rank, end_rank):
                filtered += [f for f in all_files
                             if f"pp_rank_{r}_" in os.path.basename(f)]
            files = sorted(filtered)

        if files:
            sz = sum(os.path.getsize(f) for f in files)
            disk_files.append((disk_idx, files))
            total_size += sz

    return disk_files, total_size


def cmd_run(args):
    num_disks = args.disks
    tpd = args.threads_per_disk
    chunk_size = args.chunk * 1024  # KB → bytes
    # O_DIRECT: chunk_size must be a multiple of 4096
    if chunk_size % ALIGNMENT != 0:
        chunk_size = ((chunk_size + ALIGNMENT - 1) // ALIGNMENT) * ALIGNMENT
        print(f"  [warn] chunk_size rounded up to {chunk_size//1024} KB for O_DIRECT alignment")
    mode_str = {
        "raw":         "raw O_DIRECT",
        "torch":       "torch.load + O_DIRECT",
        "safetensors": "safetensors + O_DIRECT (I/O bottleneck)",
    }[args.mode]
    ext = '.safetensors' if args.mode == 'safetensors' else '.pt'

    disk_files, total_size = collect_disk_files(num_disks, args.step, args.ranks, ext)
    if not disk_files:
        print("ERROR: no files to read. Run 'distribute' first.")
        sys.exit(1)

    total_files = sum(len(fl) for _, fl in disk_files)
    total_threads = len(disk_files) * tpd

    print("=" * 70)
    print(f"  LLaMA3-8B Checkpoint Read Benchmark")
    print(f"  Step            : {args.step}")
    if num_disks == 1:
        print(f"  Disks           : 1 (single disk mode — all ranks from testdb1)")
    else:
        print(f"  Disks           : {num_disks}")
    print(f"  Threads/disk    : {tpd}  (total {total_threads} threads)")
    print(f"  Files           : {total_files}")
    print(f"  Total size      : {total_size / GB:.1f} GB")
    print(f"  Mode            : {mode_str}")
    print(f"  Chunk           : {chunk_size/1024:.0f} KB")
    print(f"  Repeats         : {args.repeats}")
    print(f"  Read cores      : {'all' if args.read_cores == 0 else args.read_cores}")
    print("=" * 70)

    for disk_idx, files in disk_files:
        print(f"\n  [disk{disk_idx+1}]")
        for f in files:
            sz = os.path.getsize(f)
            print(f"    {sz/GB:6.1f} GB  {os.path.basename(f)}")

    # Pre-allocate per-thread I/O buffers for torch/safetensors mode
    io_bufs = []
    if args.mode in ("torch", "safetensors"):
        all_files = [f for _, fl in disk_files for f in fl]
        max_file = max(os.path.getsize(f) for f in all_files)
        buf_size = ((max_file + ALIGNMENT - 1) // ALIGNMENT) * ALIGNMENT
        n_bufs = total_threads
        print(f"\n  [alloc] {n_bufs}× {buf_size/GB:.1f} GB buffers...",
              end=" ", flush=True)
        t_a = time.monotonic()
        zero = bytes(min(chunk_size, buf_size))
        for _ in range(n_bufs):
            b = mmap.mmap(-1, buf_size)
            mv = memoryview(b)
            for off in range(0, buf_size, len(zero)):
                end = min(off + len(zero), buf_size)
                mv[off:end] = zero[:end - off]
            mv.release()
            b.seek(0)
            io_bufs.append(b)
        print(f"done ({time.monotonic() - t_a:.1f}s)")

    # CPU affinity
    if args.read_cores > 0:
        cpuset = set(range(args.read_cores))
        os.sched_setaffinity(0, cpuset)
        print(f"\n  CPU affinity: cores 0-{args.read_cores-1}")

    throughputs = []
    io_throughputs = []

    for rep in range(1, args.repeats + 1):
        drop_caches()
        time.sleep(1)

        t0 = time.monotonic()

        # tpd threads per disk — distribute files round-robin
        with ThreadPoolExecutor(max_workers=total_threads) as pool:
            futures = {}  # future → (disk_idx, thread_idx)
            buf_idx = 0
            for disk_idx, files in disk_files:
                # distribute files across tpd threads (round-robin)
                thread_file_lists = [[] for _ in range(tpd)]
                for fi, fpath in enumerate(files):
                    thread_file_lists[fi % tpd].append(fpath)

                for ti, tfl in enumerate(thread_file_lists):
                    if not tfl:
                        continue
                    if args.mode == "raw":
                        fut = pool.submit(dio_raw_read_files, tfl, chunk_size)
                    elif args.mode == "torch":
                        fut = pool.submit(dio_torch_load_files, tfl,
                                          io_bufs[buf_idx], chunk_size)
                        buf_idx += 1
                    else:  # safetensors
                        fut = pool.submit(dio_safetensors_load_files, tfl,
                                          io_bufs[buf_idx], chunk_size)
                        buf_idx += 1
                    futures[fut] = (disk_idx, ti)

            # aggregate per disk
            disk_results = {}  # disk_idx → (bytes, max_sec)
            for fut in as_completed(futures):
                disk_idx, ti = futures[fut]
                nbytes, io_sec = fut.result()
                if disk_idx not in disk_results:
                    disk_results[disk_idx] = [0, 0.0]
                disk_results[disk_idx][0] += nbytes
                disk_results[disk_idx][1] = max(disk_results[disk_idx][1], io_sec)

            read_bytes = 0
            io_sec_max = 0.0
            for disk_idx in sorted(disk_results):
                nbytes, io_sec = disk_results[disk_idx]
                read_bytes += nbytes
                io_sec_max = max(io_sec_max, io_sec)
                print(f"    [{rep}] disk{disk_idx+1}: {nbytes/GB:.1f} GB  "
                      f"I/O {io_sec:.1f}s ({nbytes/GB/io_sec:.2f} GB/s)")

        t1 = time.monotonic()
        elapsed = t1 - t0
        eff_gbps = (read_bytes / GB) / elapsed
        io_gbps = (read_bytes / GB) / io_sec_max
        throughputs.append(eff_gbps)
        io_throughputs.append(io_gbps)
        eff_gbits = eff_gbps * 8
        io_gbits = io_gbps * 8

        print(f"  [{rep}/{args.repeats}] TOTAL: {read_bytes/GB:.1f} GB  "
              f"I/O {io_sec_max:.1f}s ({io_gbps:.2f} GB/s = {io_gbits:.1f} Gbps)  "
              f"total {elapsed:.1f}s ({eff_gbps:.2f} GB/s = {eff_gbits:.1f} Gbps)\n")

    avg_eff = sum(throughputs) / len(throughputs)
    avg_io = sum(io_throughputs) / len(io_throughputs)
    print("=" * 70)
    print(f"  Results ({args.repeats} runs, {mode_str}, {num_disks} disks, {tpd} tpd, {chunk_size//1024}KB chunk)")
    print(f"  Data per run    : {total_size/GB:.1f} GB")
    print(f"  I/O throughput  : {avg_io:.2f} GB/s = {avg_io*8:.1f} Gbps  "
          f"(min {min(io_throughputs):.2f}, max {max(io_throughputs):.2f})")
    print(f"  Eff throughput  : {avg_eff:.2f} GB/s = {avg_eff*8:.1f} Gbps  "
          f"(min {min(throughputs):.2f}, max {max(throughputs):.2f})")
    if args.read_cores > 0:
        print(f"  CPU cores       : {args.read_cores}")
    print("=" * 70)

    for b in io_bufs:
        b.close()


# ───────────────────── main ─────────────────────

def main():
    parser = argparse.ArgumentParser(description="LLaMA3-8B Checkpoint DIO Bench")
    sub = parser.add_subparsers(dest="cmd")

    # convert
    p_conv = sub.add_parser("convert", help="Convert .pt checkpoints to .safetensors (testdb1 only)")
    p_conv.add_argument("--step", default="global_epoch1_step1")

    # distribute
    p_dist = sub.add_parser("distribute", help="Distribute checkpoint files to 8 disks")
    p_dist.add_argument("--step", default="global_epoch1_step1")

    # run
    p_run = sub.add_parser("run", help="Run parallel read benchmark")
    p_run.add_argument("--step", default="global_epoch1_step1")
    p_run.add_argument("--repeats", type=int, default=3)
    p_run.add_argument("--read-cores", type=int, default=0,
                       help="Pin read to N cores (0=all)")
    p_run.add_argument("--mode", choices=["raw", "torch", "safetensors"], default="raw",
                       help="raw: O_DIRECT only  torch: torch.load  safetensors: zero-copy tensors (I/O bottleneck)")
    p_run.add_argument("--ranks", type=int, default=8)
    p_run.add_argument("--disks", type=int, default=8,
                       help="Number of disks to use (1-8)")
    p_run.add_argument("--threads-per-disk", type=int, default=1,
                       help="I/O threads per disk (default: 1)")
    p_run.add_argument("--chunk", type=int, default=1280,
                       help="Chunk size in KB (default: 1280)")

    args = parser.parse_args()
    if args.cmd == "convert":
        cmd_convert(args)
    elif args.cmd == "distribute":
        cmd_distribute(args)
    elif args.cmd == "run":
        cmd_run(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
