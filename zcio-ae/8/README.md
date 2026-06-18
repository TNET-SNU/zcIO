# Artifact Evaluation for 8: PDU-aligned packetization throughput

This figure shows steady-state NVMe/TCP **read** throughput across a block-size
sweep for four network configurations, with the **target pinned to a single CPU
core** and load of **4 NVMe devices over one NIC pair**. Configs 1→4 add one
optimization at a time, isolating the contribution of PDU-aligned packetization
(`nvme_pdu_align=1`, config 4). Simply running `all_in_one.sh` would work.

```bash
cd ~/zcIO/zcio-ae/8
./all_in_one.sh
```

This is a **read-path** figure, so both hosts must be on the read kernels first
(`stream5 = 6.11.0-hostzc+`, `rapids0 = 5.15.189-pduwin`). Check (and switch, if
needed) with `./kernel-switch.sh read` (add `--reboot` to switch both hosts into
them, which reboots).

| config | E2E MTU | target TSO | nvme_pdu_align | what it adds        |
|--------|---------|------------|----------------|---------------------|
| 1      | 1500    | off        | 0              | baseline (1500 MTU) |
| 2      | 9000    | off        | 0              | jumbo frames        |
| 3      | 9000    | on         | 0              | + TSO               |
| 4      | 9000    | on         | 1              | + PDU alignment     |

After about 8 minutes, this script will print a table that looks like below.

```
############################################################
# COMBINED (4 dev/1 NIC): steady net RX throughput (GB/s) by block size
############################################################
bs                      cfg1(1500/tso-off/pa0)  cfg2(9000/tso-off/pa0)  cfg3(9000/tso-on/pa0)   cfg4(9000/tso-on/pa1)
4k                      1.28                    1.55                    1.64                    1.35
16k                     2.54                    3.80                    4.35                    3.38
32k                     3.09                    5.17                    6.34                    5.29
64k                     3.45                    6.20                    7.82                    7.10
128k                    3.71                    6.88                    8.90                    7.93
256k                    3.83                    7.24                    9.06                    8.78
512k                    3.54                    7.23                    8.88                    8.82

Per-config raw results in results-cfg{1,2,3,4}/
```

Each config should improve over the previous one at the larger block sizes. To
render the grouped bar chart:

```bash
python3 plot.py        # -> results-plot.png / results-plot.pdf
```

## Interpreting the results

Unlike the other figures, the thing to note here is not run-to-run variance but an
**overall difference in scale**: the absolute GB/s you measure may sit uniformly
above or below the reference table. That is because **the reference numbers were
collected on a different test machine** than the one this artifact now runs on, so
the absolute level shifts even though the experiment is the same. Compare the
**trend across configs**, not the absolute numbers.

The trend should still hold, and the reproduction is successful if it does:

- Each config improves over the previous one at the larger block sizes
  (`cfg1` < `cfg2` < `cfg3`), as jumbo frames and TSO are added.
- Most importantly, **`cfg4` (zcIO, PDU-aligned) tracks `cfg3` (TSO) closely at the
  large block sizes** — in the reference table they are within a few percent at
  256k/512k (`8.78` vs `9.06`, `8.82` vs `8.88`). This is the point of the figure:
  turning on PDU-aligned packetization in zcIO is **not a large overhead** on top
  of TSO, even though it constrains how the target packetizes the read stream.
- At the small block sizes `cfg4` sits a bit below `cfg3` (the per-PDU alignment
  cost is relatively larger when payloads are small), but that gap closes as the
  block size grows.

## How it works

Two machines (see the top-level README topology): the **target** (`rapids0`)
exports the 4 NVMe/TCP subsystems on one NIC and is pinned to a single CPU core;
the **host** (`stream5`, where you run this) connects to all four and drives a
read block-size sweep, sampling the steady-state RX throughput on the matching
initiator NIC. `all_in_one.sh` first stages its `rapids0/` scripts to the target,
brings up the datapath once, then for each of the four configs applies the target
MTU/TSO/`nvme_pdu_align` (`caseN.sh`) and runs the sweep (`workload.sh`). Config 4
turns on `nvme_pdu_align`, which makes the target emit PDU-aligned NVMe/TCP data
on the read path — so configs 3 and 4 differ even for reads.

This is a **READ-path** experiment, so it requires the read kernels
(host `6.11.0-hostzc+`, target `5.15.189-pduwin`). Verify (and switch, if needed)
with `./kernel-switch.sh read` — run all read figures before the write figures
(see the top-level README ordering).

If some values are `-` or 0, refer to the top-level README.
