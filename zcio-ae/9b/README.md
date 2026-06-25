# Artifact Evaluation for 9b: UNet3D CPU-core scaling

This figure shows how many **CPU cores** the initiator needs to keep 8 simulated
H100 accelerators fed during MLPerf Storage **UNet3D** NVMe/TCP reads, under the
stock-Linux baseline vs **zcIO** (kernel NVMe/TCP zero-copy). The metric is
**AU% (Accelerator Utilization)** as the number of ONLINE CPU cores is swept
`1, 2, 4, 6, 8, 10`. zcIO needs fewer cores to reach the AU≥90% target because its
zero-copy read path spends less CPU per byte.

| config  | initiator (stream5) | target (rapids0) |
|---------|---------------------|------------------|
| default | ZCOPY off           | nvme_pdu_align 0 |
| zcIO    | ZCOPY on            | nvme_pdu_align 2 |

Cores are reduced by **offlining** (`set-cores.sh N`), not taskset — offlining
makes DLIO/MPI see exactly N CPUs; taskset crams all ranks onto a few cores and
deadlocks at the epoch-end barrier.

## Prerequisites (one-time)

The shared MLPerf env (`/opt/mlperf-env`: venv + modified mlpstorage + dlio) is
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
cd ~/zcIO/zcio-ae/9b
./all_in_one.sh
```

By default this runs the **3-point comparison** — default @ 6 and 10 cores, zcIO @
6 cores — which is enough to show zcIO reaches the AU≥90% target at fewer cores.
For the **full sweep** (`1, 2, 4, 6, 8, 10` cores per config) run
`./all_in_one_full.sh` instead — **about 40 minutes** (the per-config dataset
generation dominates).

Per config it brings up NVMe/TCP at full cores, stages the dataset, then sweeps
online-core counts running mlpstorage and parsing the steady-state (epoch-2) AU%.
It prints a table and writes `results-plot.png` (+ `.pdf`):

```
cores       default     zcIO         (AU %)
1           14.19       26.00
2           28.40       52.00
4           55.00       88.00
6           78.00       96.00
8           92.00       97.00
10          95.00       98.00
```

zcIO should hit AU≥90% at fewer cores than default. Per-config CSVs land in
`results/coresweep-unet3d-{default,zcIO}.csv`; render with `python3 plot.py`.

## Subsetting

The full sweep takes `CONFIGS` / `CORES` overrides:

```bash
CONFIGS="default" CORES="2 4 8" ./all_in_one_full.sh
```
