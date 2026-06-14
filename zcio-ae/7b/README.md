# Artifact Evaluation for 7b: random-write throughput vs target CPU-core count (linux / SPDK / zcIO)

This figure shows fixed-256k **random-write** throughput as a line chart, with
**x = the target (`rapids0`) CPU-core count** and one line per config
(`linux`, `spdk`, `zcIO-MT`, `zcIO-MP`). Data flows **stream5 → rapids0**, so the
sender (`stream5`) runs at full cores while only the receiver (`rapids0`) is
core-swept (15 → 12 → 8 → 4 → 2 → 1). Simply running `all_in_one.sh` would work.

```bash
cd ~/zcIO/zcio-ae/7b
./all_in_one.sh
```

After about 15 minutes, this script prints a table that looks like below. The
example shows the `spdk` series (collected on this machine); the remaining
series (`linux`, `zcIO-MT`, `zcIO-MP`) are produced at runtime.

```
############################################################
# COMBINED: steady net TX (GB/s) by rapids0 core count
############################################################
cores             linux             zcIO-MT           zcIO-MP           spdk
1                 -                 -                 -                 4.28
2                 -                 -                 -                 6.97
4                 -                 -                 -                 12.32
8                 -                 -                 -                 22.55
12                -                 -                 -                 25.69
15                -                 -                 -                 27.93

Plot with:  python3 plot.py
```

To render the line chart:

```bash
python3 plot.py        # -> results-plot.png / results-plot.pdf
```

## How it works

Two machines (see the top-level README topology). `stream5` is the **sender**,
held at **full cores**; `rapids0` is the **receiver** and is the **core-swept**
side. For the kernel configs (`linux`, `zcIO-MT`, `zcIO-MP`) the 8 subsystems are
connected once at full cores, then `rapids0` cores are progressively offlined and
IRQs re-pinned at each step (no reload, no reconnect). `spdk` fixes its core count
at launch, so it restarts the target and reconnects at each core count. Throughput
is the **summed initiator TX** (`tx_bytes`) over both NICs, sampled at steady
state.

This is a **WRITE-path** experiment, so it requires the write kernels
(host `stream5` = `5.15.189-pduwin`, target `rapids0` = `6.11.0-target-zc-add-frozen+`).
Verify (and switch, if needed) with `./kernel-switch.sh write` — which reboots —
and run all write figures **after** the read figures (see the top-level README
ordering).

The `spdk` config requires SPDK pre-installed at `/opt/spdk` on `rapids0`
(`spdk-target-start.sh` / `spdk-target-stop.sh` are bundled in `rapids0/`).

If some values are `-` or 0, refer to the top-level README.
