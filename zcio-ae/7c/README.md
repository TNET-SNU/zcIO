# Artifact Evaluation for 7c: read throughput with the initiator limited to 1 CPU core (linux vs zcIO)

This figure runs the same 4-device / 1-NIC NVMe/TCP **random-read** sweep as
figure 8, but moves the bottleneck to the **initiator**: the target (`rapids0`)
keeps all its CPU cores, while the host (`stream5`, where you run this) is
intentionally pinned to a **single CPU core**. With the receiver CPU-starved, the
cost of the receive path dominates — which is exactly where zcIO's zero-copy
receive wins. Simply running `all_in_one.sh` would work.

```bash
cd ~/zcIO/zcio-ae/7c
./all_in_one.sh
```

After about 15 minutes, this script will print a table that looks like below.

```
############################################################
# COMBINED (stream5 1-core): steady net RX throughput (GB/s) by block size
############################################################
bs                linux             zcIO              spdk
4k              0.93              0.89              2.12
16k             2.59              2.61              3.37
32k             3.69              4.27              4.00
64k             4.50              6.62              4.82
128k            5.19              8.35              5.95
256k            5.38              9.98              6.45
512k            5.61              11.11             6.97

Per-config raw results in results-<name>/  (linux zcIO spdk)
```

At the smallest block size (4k) SPDK leads, since its interrupt-free design wins
when each transfer is tiny. From 32k onward zcIO surpasses both baselines: its
zero-copy receive removes the per-byte copy that saturates the single host core,
so at 512k it reaches ~2.0x the linux baseline and ~1.6x SPDK. To render the
grouped bar chart:

```bash
python3 plot.py        # -> results-plot.png / results-plot.pdf
```

## How it works

Two machines (see the top-level README topology): the **target** (`rapids0`)
exports 4 NVMe/TCP subsystems on one NIC (`ens17np0`) and runs with **full CPU
cores**; the **initiator** (`stream5`, where you run this) is **intentionally
pinned to a single CPU core** (`cpu-limit-1core.sh`), so the receiver's CPU
efficiency is the bottleneck — this is where zcIO's zero-copy receive helps
most. `all_in_one.sh` first self-stages its `rapids0/` scripts to the target
(`$RAPIDS0_DIR`, default `/home/fast27/zcio-ae-7c`), brings up the datapath once,
then for each named config (`linux`, `zcIO`, `spdk`) applies that config's
environment (`case-<name>.sh`) and runs the read sweep (`workload.sh`). At the
end it restores the host's cores and net config and resets the target baseline.

This is a **READ-path** experiment, so it requires the read kernels
(host `stream5` = `6.11.0-hostzc+`, target `rapids0` = `5.15.189-pduwin`). Verify
(and switch, if needed) with `./kernel-switch.sh read` — run all read figures
before the write figures (see the top-level README ordering).

If some values are `-` or 0, refer to the top-level README.
