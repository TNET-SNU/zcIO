# Artifact Evaluation for 7a: random-write throughput vs block size (linux / SPDK / zcIO)

This figure shows steady-state NVMe/TCP **random-write** throughput across a
block-size sweep, comparing three datapaths — the stock Linux kernel target
(`linux`), an SPDK target (`spdk`), and receive zero-copy (`zcIO`) — with the
**target (`rapids0`) pinned to a single CPU core** as the bottleneck under test.
Simply running `all_in_one.sh` would work.

```bash
cd ~/zcIO/zcio-ae/7a
./all_in_one.sh
```

This is a **write-path** figure, so both hosts must be on the write kernels first
(`stream5 = 5.15.189-pduwin`, `rapids0 = 6.11.0-target-zc-add-frozen+`). Check (and
switch, if needed) with `./kernel-switch.sh write` (add `--reboot` to switch both
hosts into them, which reboots).

After about 13 minutes, this script will print a table that looks like below.

```
############################################################
# COMBINED (rapids0 1-core): steady net TX (GB/s) by block size
############################################################
bs                linux             zcIO              spdk
4k                1.22              1.22              1.45
16k               2.69              2.95              2.24
32k               3.38              4.62              3.28
64k               3.79              6.16              4.00
128k              4.16              7.41              5.01
256k              4.29              8.30              5.56
512k              4.40              9.16              5.38

Plot with:  python3 plot.py
```

`zcIO` should outperform `linux` (and SPDK at the larger block sizes). To render
the grouped bar chart:

```bash
python3 plot.py        # -> results-plot.png / results-plot.pdf
```

## Interpreting the results

The absolute GB/s numbers carry some run-to-run variance, so do not expect them to
match the table above exactly. The variance is **largest at the big block sizes**,
where the workload exercises the target SSDs' raw NAND bandwidth and exposes their
**device-internal variability** — the small-block points are IOPS-bound and
comparatively stable. That device-internal variability comes from:

1. **Garbage collection** — NAND erases in large blocks but writes in pages, so as
   the drive fills its background GC competes with host writes for NAND bandwidth,
   making throughput fluctuate.
2. **SLC cache / write cliff** — TLC/QLC drives absorb writes in a fast SLC region
   and drop to slow native speed once it fills; our scripts re-format the drives to
   write only in SLC and reset this cache each run, but the automation may still
   proceed with the cache not fully reset, which shows up as variance.
3. **Fresh vs steady-state** — a freshly erased/trimmed drive writes fast, but once
   it is "dirty" write amplification and GC kick in, lowering and destabilizing
   throughput.
4. **Thermal throttling** — sustained large-block writes heat the controller/NAND
   and trigger intermittent throttling.

On top of the device side, the single-core target itself contributes a little
variance even when fully saturated, as the one receive core's throughput shifts
slightly with scheduling and interrupt/softirq timing.

What matters is the **trend**, and the reproduction is successful if it holds:

- **`zcIO` reaches ≥ 2× the `linux` baseline** at the larger block sizes (roughly
  128k and above), where zero-copy receive eliminates the per-byte copy cost on
  the single-core target. In the reference table this is ~2.1× at 512k
  (`9.16` vs `4.40`).
- **`spdk` stays below ~1.5× the `linux` baseline** across the sweep — it helps,
  but well short of `zcIO`. In the reference table SPDK peaks around 1.3×.
- At the smallest block size (`4k`) the three are close; the gap opens up as the
  block size grows. This per-byte-copy ordering — `zcIO` > `spdk` > `linux` at
  large block sizes — is the claim of the figure.

## How it works

Two machines (see the top-level README topology): the **host** (`stream5`, where
you run this) is the **SENDER** and runs at **full cores**; the **target**
(`rapids0`) is the **RECEIVER** and is limited to a **single CPU core**, which is
the bottleneck this figure stresses. This is the single-core figure, so the load
is **4 NVMe devices over one NIC** (`ens17np0`) — a second NIC isn't needed when
one target core is the limit. Because this is a write workload, data flows
`stream5 -> rapids0`, so throughput is the **initiator TX on that data NIC**.
For each config `all_in_one.sh` brings up the datapath, sweeps the block sizes,
and records GB/s. `linux` runs the kernel nvmet target with zero-copy off; `spdk`
runs an SPDK target on one core; `zcIO` runs the kernel target with receive
zero-copy on (and PDU alignment on the sender) — isolating zero-copy's
contribution. The script **self-stages its `rapids0/` scripts** to the target each
run and **onlines all host cores** so the sender never accidentally becomes the
bottleneck.

This is a **WRITE-path** experiment, so it requires the write kernels
(host `stream5` = `5.15.189-pduwin`, target `rapids0` = `6.11.0-target-zc-add-frozen+`).
Verify (and switch, if needed) with `./kernel-switch.sh write` (this reboots the
machines). Run all read figures **before** the write figures (see the top-level
README ordering).

The `spdk` config requires SPDK to be pre-installed at `/opt/spdk` on `rapids0`
(the bundled `rapids0/spdk-target-start.sh` / `spdk-target-stop.sh` call
`SPDK_DIR=/opt/spdk`).

If some values are `-` or 0, refer to the top-level README.
