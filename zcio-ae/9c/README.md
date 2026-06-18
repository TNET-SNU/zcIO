# Artifact Evaluation for 9c: RocksDB single-core read IOPS

This figure shows single-core **RocksDB** random-read (`readrandom`) IOPS over
NVMe/TCP, under the stock-Linux baseline vs **zcIO** (kernel NVMe/TCP zero-copy),
across a block-size sweep. The DB lives on 4 NVMe/TCP devices; the initiator runs
the read with a single CPU core so the per-byte CPU cost of the read path
(default copy vs zcIO zero-copy) shows up directly in ops/s.

| config  | initiator (stream5) | target (rapids0) |
|---------|---------------------|------------------|
| default | ZCOPY off           | nvme_pdu_align 0 |
| zcIO    | ZCOPY on            | nvme_pdu_align 2 |

## Prerequisites (one-time)

The shared RocksDB env (`/opt/rocksdb-env`: custom_rocksdb + librocksdb.so) is
pre-provisioned on this machine and readable by every account — no install step.
You only need:

```bash
cd ~/zcIO/zcio-ae && ./deploy.sh        # global passwordless SSH + NOPASSWD sudo
```

Read-path kernels (verified by the script via `./kernel-switch.sh read`):
`stream5 = 6.11.0-hostzc+`, `rapids0 = 5.15.189-pduwin`. Check or switch yourself
with `./kernel-switch.sh read` (add `--reboot` to switch both hosts into them,
which reboots).

## Run

```bash
cd ~/zcIO/zcio-ae/9c
./all_in_one.sh
```

**Takes about 10 minutes.**

Per config it brings up NVMe/TCP, mkfs+mounts the 4 devices, and runs the
single-core RocksDB read sweep. It prints a combined IOPS-by-block-size table and
writes the plot:

```
############################################################
# COMBINED: single-core RocksDB readrand IOPS (ops/s) by block size
############################################################
bs        default      zcIO
...
```

zcIO should beat default, more so at smaller block sizes (copy cost dominates).
Per-config CSVs land in `results-rocksdb-{default,zcIO}.csv`; render with
`python3 plot.py`.

## Subsetting

```bash
CONFIGS="default" ./all_in_one.sh
```
