#!/usr/bin/env python3
# plot.py — grouped BAR chart of total HTTP throughput (GB/s): linux vs zcIO,
# per file size. Reads results/summary.csv and writes
# results-plot.png + results-plot.pdf (same convention as zcio-ae fig-7c).
#
# Usage:
#   python3 plot.py [--results-dir results] [--out results-plot.png]
#                   [--metric total_GBps] [--title "..."]
# Requires matplotlib:  pip install --user matplotlib
import argparse, csv, os, sys

# config (paper naming) -> (legend label, bar color). Order = bar order in group.
MODES = [
    ("linux", "linux", "#1f77b4"),
    ("zcIO",  "zcIO",  "#d62728"),
]

# old summary.csv files used off/on; map them onto the paper naming so legacy
# results still plot.
LEGACY = {"off": "linux", "on": "zcIO"}

def size_to_bytes(sz):
    s = sz.strip().lower(); mult = 1
    if s.endswith("k"):   mult, s = 1024, s[:-1]
    elif s.endswith("m"): mult, s = 1024 * 1024, s[:-1]
    elif s.endswith("g"): mult, s = 1024 ** 3, s[:-1]
    try:    return int(float(s) * mult)
    except ValueError: return 0

def read_summary(path, metric):
    """Return {(config, size): value} from summary.csv (config,size,total_GBps,...)."""
    out = {}
    if not os.path.exists(path):
        sys.exit(f"ERROR: {path} not found — run ./all_in_one.sh first")
    with open(path) as f:
        rdr = csv.DictReader(f)
        col = metric if metric in (rdr.fieldnames or []) else None
        if col is None:
            for alt in ("total_GBps", "total_rps"):
                if alt in (rdr.fieldnames or []): col = alt; break
        if col is None:
            sys.exit(f"ERROR: no throughput column in {path}")
        for row in rdr:
            cfg = row.get("config", row.get("zc"))   # accept old "zc" header too
            cfg = LEGACY.get(cfg, cfg)                # off/on -> linux/zcIO
            try:    out[(cfg, row["size"])] = float(row[col])
            except (KeyError, ValueError, TypeError): pass
    return out

def main():
    ap = argparse.ArgumentParser(description="nginx-ae grouped bar chart")
    ap.add_argument("--results-dir", default="results")
    ap.add_argument("--out", default="results-plot.png")
    ap.add_argument("--metric", default="total_GBps")
    ap.add_argument("--title", default="nginx over NVMe/TCP — linux vs zcIO")
    args = ap.parse_args()

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        sys.exit("ERROR: matplotlib/numpy not installed. Run: pip install --user matplotlib")

    data = read_summary(os.path.join(args.results_dir, "summary.csv"), args.metric)
    sizes = sorted({sz for (_, sz) in data}, key=size_to_bytes)
    if not sizes:
        sys.exit("ERROR: no rows in summary.csv")

    x = np.arange(len(sizes))
    n = len(MODES); width = 0.8 / n
    plt.figure(figsize=(8, 4.5))
    for i, (zc, label, color) in enumerate(MODES):
        y = [data.get((zc, sz), 0.0) for sz in sizes]
        offs = (i - (n - 1) / 2) * width
        bars = plt.bar(x + offs, y, width, label=label, color=color,
                       edgecolor="black", linewidth=0.4)
        plt.bar_label(bars, fmt="%.2f", fontsize=8, padding=2)

    plt.xticks(x, sizes)
    plt.xlabel("File size")
    plt.ylabel("Total HTTP throughput (GB/s)")
    plt.title(args.title)
    plt.grid(True, axis="y", linestyle="--", alpha=0.4)
    plt.legend(title="Config")
    plt.ylim(bottom=0)
    plt.tight_layout()

    plt.savefig(args.out, dpi=150)
    if args.out.lower().endswith(".png"):
        pdf = args.out[:-4] + ".pdf"; plt.savefig(pdf); print(f"wrote {args.out} and {pdf}")
    else:
        print(f"wrote {args.out}")

if __name__ == "__main__":
    main()
