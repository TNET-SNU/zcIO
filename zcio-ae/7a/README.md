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

After about 15 minutes, this script will print a table that looks like below.

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
