# Artifact Evaluation for 9a: MLPerf Storage single-core read bandwidth

This figure shows single-core NVMe/TCP **read** bandwidth for three MLPerf Storage
workloads — **UNet3D**, **Llama3 (checkpoint load)**, **CosmoFlow** — under the
stock-Linux baseline vs **zcIO** (kernel NVMe/TCP zero-copy). The metric is the
peak incoming bandwidth on the data NIC `ens2np0` while the initiator is pinned to
a single CPU core. Every workload reads with `O_DIRECT` so each read actually
crosses the network (page cache bypassed), which is what makes the zero-copy
effect measurable.

| config  | initiator (stream5) | target (rapids0) |
|---------|---------------------|------------------|
| default | ZCOPY off           | nvme_pdu_align 0 |
| zcIO    | ZCOPY on            | nvme_pdu_align 2 |

## Prerequisites (one-time)

The shared MLPerf env already lives in `/opt/mlperf-env` (venv + modified
mlpstorage + dlio O_DIRECT readers), pre-provisioned on this machine and readable
by every account — you do **not** install anything. You only need global
passwordless SSH + NOPASSWD sudo:

```bash
cd ~/zcIO/zcio-ae && ./deploy.sh
```

Read-path kernels must be booted (the script verifies and stops if not):
`stream5 = 6.11.0-hostzc+`, `rapids0 = 5.15.189-pduwin`. Switch with
`sudo ./reboot-to-kernel.sh 6.11` (stream5) / boot `5.15.189-pduwin` on rapids0.

## Run

```bash
cd ~/zcIO/zcio-ae/9a
./all_in_one.sh
```

**Takes about 40 minutes** (the per-config dataset generation dominates).

`all_in_one.sh` verifies the kernels + /opt env, stages the `rapids0/` target
scripts, then for each config (default, zcIO) brings up NVMe/TCP and runs the
three workloads (mount → datagen → single-core O_DIRECT read → peak Gbps). After
it finishes it prints a table and writes `results/fig-9a-mlperf.png`:

```
workload        default         zcIO            speedup          (peak incoming Gbps)
UNet3D          4.10            9.80            2.39x
Llama3 (load)   3.20            7.50            2.34x
CosmoFlow       2.10            10.30           4.90x
```

zcIO should outperform default on every workload. Per-workload CSVs land in
`results/<workload>-{default,zcIO}.csv`; render the chart with `python3 plot.py`.

## Subsetting

```bash
CONFIGS="default" WORKLOADS="unet3d" ./all_in_one.sh   # one config / one workload
```
