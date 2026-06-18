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

After about 37 minutes, this script prints a table that looks like below. The
example shows the `spdk` series (collected on this machine); the remaining
series (`linux`, `zcIO-MT`, `zcIO-MP`) are produced at runtime.

```
############################################################
# COMBINED: steady net TX (GB/s) by rapids0 core count
############################################################
cores             linux             zcIO-MT           zcIO-MP           spdk
1                 3.65              6.99              6.96              4.82
2                 3.70              11.89             12.23             8.39
4                 10.15             22.74             22.97             14.27
8                 16.95             36.33             37.97             23.83
12                21.25             46.35             49.31             30.14
15                22.65             51.38             51.82             32.98

Plot with:  python3 plot.py
```

To render the line chart:

```bash
python3 plot.py        # -> results-plot.png / results-plot.pdf
```

## Interpreting the results

The absolute GB/s numbers carry some run-to-run variance, so do not expect them to
match the table above exactly. This figure is fixed at **256k**, a large block, so
every point exercises the target SSDs' raw NAND bandwidth and carries the
**device-internal variability** below; on top of that, the figure **sweeps the
target core count**, and at the low core counts the receive CPU is the bottleneck,
so its saturated throughput shifts a little with scheduling and interrupt/softirq
timing. The device-internal variability comes from:

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

What matters is the **trend**, and the reproduction is successful if it holds:

- **`zcIO` (`MT`/`MP`) reaches ≥ 2× the `linux` baseline at the low core counts**,
  where the receive CPU is scarce and zero-copy's saved per-byte copy matters most.
- **`spdk` stays below ~1.5× the `linux` baseline** at those low core counts — it
  helps, but well short of `zcIO`.
- As the core count grows, every config rises toward the NIC/link limit and the
  lines converge; `zcIO` reaches a given throughput with **fewer target cores**.
  This core-efficiency ordering — `zcIO` > `spdk` > `linux` when cores are scarce —
  is the claim of the figure.

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
