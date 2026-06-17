#!/usr/bin/env python3
# plot.py — fig-9a RocksDB single-core read IOPS: default vs zcIO grouped bars.
#
# Reads results-rocksdb-<config>.csv (written by rocksdb-run.sh / all-in-one.sh);
# uses the per-bs "avg" rows. X = block size, one bar group per bs, one bar per
# config. Y = readrand throughput (ops/s = IOPS).
#
# Usage:
#   python3 plot.py                          # default+zcIO -> results-plot.png/.pdf
#   python3 plot.py --configs default zcIO --out results-plot.png
#
# Requires matplotlib:  pip install --user matplotlib
import argparse, csv, os, sys

CONFIG_STYLE = {            # config -> (legend label, color)
    "default": ("Linux (default)", "#7f7f7f"),
    "zcIO":    ("zcIO",            "#d62728"),
}
BS_ORDER = ["4k", "32k", "64k", "128k", "256k"]

def read_avg(path):
    """Return {bs: ops_per_s(float)} from the 'avg' rows of a results CSV."""
    out = {}
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for row in csv.DictReader(f):
            if row.get("rep") == "avg":
                try: out[row["bs"]] = float(row["ops_per_s"])
                except (ValueError, KeyError): pass
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--configs", nargs="+", default=["default", "zcIO"])
    ap.add_argument("--results-prefix", default="results-rocksdb-")
    ap.add_argument("--out", default="results-plot.png")
    args = ap.parse_args()

    data = {c: read_avg(f"{args.results_prefix}{c}.csv") for c in args.configs}
    present = [c for c in args.configs if data[c]]
    if not present:
        sys.exit("no results-rocksdb-*.csv found — run ./all-in-one.sh first")

    bslist = [bs for bs in BS_ORDER if any(bs in data[c] for c in present)]

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("matplotlib not installed: pip install --user matplotlib")

    import numpy as np
    x = np.arange(len(bslist))
    n = len(present)
    w = 0.8 / n
    fig, ax = plt.subplots(figsize=(8, 4.5))
    for i, c in enumerate(present):
        label, color = CONFIG_STYLE.get(c, (c, None))
        vals = [data[c].get(bs, 0) / 1000.0 for bs in bslist]   # kIOPS
        ax.bar(x + (i - (n - 1) / 2) * w, vals, w, label=label, color=color)

    ax.set_xticks(x); ax.set_xticklabels(bslist)
    ax.set_xlabel("RocksDB value size")
    ax.set_ylabel("Read throughput (kIOPS)")
    ax.set_title("fig-9a: single-core RocksDB point-lookup (NVMe/TCP)")
    ax.legend(); ax.grid(axis="y", ls=":", alpha=0.5)
    fig.tight_layout()

    fig.savefig(args.out, dpi=150)
    pdf = os.path.splitext(args.out)[0] + ".pdf"
    fig.savefig(pdf)
    print(f"wrote {args.out} and {pdf}")

if __name__ == "__main__":
    main()
