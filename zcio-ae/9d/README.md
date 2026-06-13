# Artifact Evaluation for 9d: nginx over NVMe/TCP — linux vs zcIO

This figure shows the total HTTP throughput an nginx file server achieves over
NVMe/TCP, comparing the stock Linux datapath (`linux`) against receive zero-copy
(`zcIO`), swept over file sizes 512k / 1M / 100M. Simply running `all_in_one.sh`
would work.

```bash
cd ~/zcIO/zcio-ae/9d
./all_in_one.sh
```

After about 20 minutes, this script will print a table that looks like below.

```
############################################################
# SUMMARY (total HTTP throughput, GB/s)
############################################################
config  size  total_GBps  total_rps
linux   512k  3.5         7116.9
linux   1M    3.5         3627.9
linux   100M  3.8         39.0
zcIO    512k  4.2         8613.0
zcIO    1M    4.6         4750.1
zcIO    100M  4.6         46.6

    raw logs: /home/syeon/zcIO/zcio-ae/9d/results/<linux|zcIO>/<size>.log
    csv     : /home/syeon/zcIO/zcio-ae/9d/results/summary.csv
    plot    : python3 plot.py
```

`zcIO` should outperform `linux` at every size. To render the grouped bar chart:

```bash
python3 plot.py        # -> results-plot.png / results-plot.pdf
```

## How it works

Three machines (see the top-level README topology): the **target** (`rapids0`)
exports 4× Samsung 9100 PRO as NVMe/TCP subsystems; the **host** (`stream5`, where
you run this) connects to all four, mounts them, and serves the files with nginx
pinned to a single core; the **client** (`creek1`) drives 4× parallel `wrk` and
the script sums their throughput. For each config it brings up the datapath,
sweeps the file sizes, and records GB/s. `linux` runs with zero-copy off; `zcIO`
turns on receive zero-copy on the host (`enable_zerocopy=1`) and PDU alignment on
the target — isolating zero-copy's contribution.

This is a **READ-path** experiment, so it requires the read kernels
(host `6.11.0-hostzc+`, target `5.15.189-pduwin`). `all_in_one.sh` checks this and,
if the kernels don't match, prints the one command to switch — see the top-level
README ordering (run all read figures before the write figures).

If some values are N/A or 0, refer to the top-level README.
