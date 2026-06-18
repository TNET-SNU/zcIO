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

This is a **read-path** figure, so both hosts must be on the read kernels first
(`stream5 = 6.11.0-hostzc+`, `rapids0 = 5.15.189-pduwin`). Check (and switch, if
needed) with `./kernel-switch.sh read` (add `--reboot` to switch both hosts into
them, which reboots).

After about 17 minutes, this script will print a table that looks like below.

```
############################################################
# COMBINED: steady net RX (GB/s) by stream5 cores, 256k randread
############################################################
cores       linux       zcIO-MT     zcIO-MP     spdk
1           4.51        8.06        7.76        4.83
2           8.82        14.32       14.06       9.09
4           14.38       25.60       25.87       16.03
8           23.52       44.15       44.98       31.00
12          30.99       57.24       56.41       35.52
15          34.14       68.62       66.74       38.23

Per-config raw results in results-<name>/  (linux zcIO-MT zcIO-MP spdk)
```

Both zcIO variants scale well past the `linux` baseline as cores increase. To
render the line chart:

```bash
python3 plot.py        # -> results-plot.png / results-plot.pdf
```

## Interpreting the results

The absolute GB/s numbers carry some run-to-run variance — throughput shifts a
little with scheduling and interrupt/softirq timing on the host cores. What matters
is the **trend**, and the reproduction is successful if it holds:

- Both **`zcIO` variants (`MP`/`MT`) scale well past the `linux` baseline** as cores
  increase, reaching ~2× linux at 15 cores.
- **`zcIO-MP` and `zcIO-MT` stay nearly equal** across the whole core sweep — this
  is the key point. `MT` (multi-thread) shares a single address space, so unmapping
  zero-copy pages would normally fire cross-core **TLB shootdowns** (IPIs) that `MP`
  (separate per-process address spaces) avoids; multi-threaded receive would then
  fall behind at higher core counts. Because `MT` keeps pace with `MP` here, zcIO
  has **essentially eliminated that TLB-shootdown overhead**.
- **`spdk` tracks the `linux` baseline** — no zero-copy win on the receive path.
- This ordering — `zcIO-MP` ≈ `zcIO-MT` ≫ `linux` ≈ `spdk` — is the claim of the
  figure.

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
