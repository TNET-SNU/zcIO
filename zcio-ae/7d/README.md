# Artifact Evaluation for 7d: read throughput vs initiator CPU-core count (linux / SPDK / zcIO-MP / zcIO-MT)

This figure shows steady-state NVMe/TCP **read** throughput for a fixed
**256k random-read** workload over **8 NVMe devices / 2 NIC pairs**, while the
**initiator (`stream5`) CPU-core count is swept** `{1, 2, 4, 8, 12, 15}`. The
**target (`rapids0`) stays at full cores**, so the curves isolate how each
datapath scales with host CPU. Four series: **linux** (zcopy off), **SPDK**, and
zcIO in two fio modes — **zcIO-MP** (multi-process) and **zcIO-MT** (multi-thread),
both with zcopy on. Simply running `all_in_one.sh` would work.

```bash
cd ~/zcIO/zcio-ae/7d
./all_in_one.sh
```

After about 30 minutes, this script will print a table that looks like below.

```
############################################################
# COMBINED: steady net RX (GB/s) by stream5 cores, 256k randread
############################################################
cores       linux       zcIO-MT     zcIO-MP     spdk
1           4.46        7.36        7.82        4.64
2           8.35        13.58       14.09       5.22
4           14.01       23.09       25.14       9.80
8           24.33       41.21       43.72       24.05
12          30.14       48.21       53.67       29.41
15          32.40       51.33       59.25       31.50

Per-config raw results in results-<name>/  (linux zcIO-MT zcIO-MP spdk)
```

Both zcIO variants scale well past the `linux` baseline as cores increase. To
render the line chart:

```bash
python3 plot.py        # -> results-plot.png / results-plot.pdf
```

## How it works

Two machines (see the top-level README topology): the **target** (`rapids0`)
exports the 8 NVMe/TCP subsystems over two NIC pairs and **stays at full cores**;
the **host** (`stream5`, where you run this) connects to all of them and drives
the fixed 256k random-read workload while its own **CPU-core count is swept**
`{1, 2, 4, 8, 12, 15}`. The figure manages the host cores itself: for each config
it onlines all cores (`cpu-limit.sh $MAXCORES`) so the NVMe/TCP multi-queue
connect happens at full cores, then `workload.sh` offlines down to each core
count for the fio run. There is **one series per config** (linux / SPDK /
zcIO-MP / zcIO-MT). `all_in_one.sh` first **self-stages its `rapids0/` scripts** to the
target (`stage_to`), brings up the datapath once, then sweeps each config.

This is a **READ-path** experiment, so it requires the read kernels
(host `6.11.0-hostzc+`, target `5.15.189-pduwin`). Verify (and switch, if needed)
with `./kernel-switch.sh read` — run all read figures before the write figures
(see the top-level README ordering).

If some values are `-` or 0, refer to the top-level README.
