#!/usr/bin/env python3
# plot.py (fig-7a) — grouped BAR chart of steady NVMe/TCP random-WRITE TX throughput vs
# block size for the two configs:
#
#   cfg3 -> "linux"   (zero-copy off)
#   cfg4 -> "zcIO"    (zero-copy on)
#
# Reads results-cfg{3,4}/summary.csv (column net_steady_GBps) and writes
# results-plot.png + results-plot.pdf.
#
# Usage:
#   python3 plot.py [--results-dir DIR] [--out FILE.png] [--metric net_steady_GBps]
# Requires matplotlib:  pip install --user matplotlib
import argparse, csv, os, sys

# results dir name -> (legend label, bar color). Order = bar order within each group.
CONFIGS = [
    ("linux", "linux", "#1f77b4"),
    ("spdk",  "SPDK",  "#2ca02c"),
    ("zcIO",  "zcIO",  "#d62728"),
]

def bs_to_bytes(bs):
    s = bs.strip().lower(); mult = 1
    if s.endswith("k"): mult, s = 1024, s[:-1]
    elif s.endswith("m"): mult, s = 1024 * 1024, s[:-1]
    try:    return int(float(s) * mult)
    except ValueError: return 0

def read_summary(path, metric):
    if not os.path.exists(path): return {}
    out = {}
    with open(path) as f:
        rdr = csv.DictReader(f)
        col = metric if metric in (rdr.fieldnames or []) else None
        if col is None:
            for alt in ("net_steady_GBps", "net_peak_GBps", "net_GBps"):
                if alt in (rdr.fieldnames or []): col = alt; break
        if col is None:
            print(f"  warn: no throughput column in {path}", file=sys.stderr); return {}
        for row in rdr:
            try:    out[row["bs"]] = float(row[col])
            except (KeyError, ValueError): pass
    return out

def main():
    ap = argparse.ArgumentParser(description="fig-7c grouped bar chart")
    ap.add_argument("--results-dir", default=".")
    ap.add_argument("--out", default="results-plot.png")
    ap.add_argument("--metric", default="net_steady_GBps")
    ap.add_argument("--title", default="NVMe/TCP random-write throughput vs block size (rapids0 1-core)")
    args = ap.parse_args()

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("ERROR: matplotlib not installed. Run:  pip install --user matplotlib")

    data, all_bs = {}, set()
    for cid, *_ in CONFIGS:
        d = read_summary(os.path.join(args.results_dir, f"results-{cid}", "summary.csv"), args.metric)
        data[cid] = d; all_bs |= set(d)
    if not all_bs:
        sys.exit(f"ERROR: no summary.csv data under {args.results_dir}/results-{{{','.join(c for c,*_ in CONFIGS)}}}/")

    # x order: the actual block-size keys, sorted by real size (4k..512k).
    bs_order = sorted(all_bs, key=bs_to_bytes)

    import numpy as np
    x = np.arange(len(bs_order))
    n = len(CONFIGS); width = 0.8 / n

    plt.figure(figsize=(9, 5))
    for i, (cid, label, color) in enumerate(CONFIGS):
        d = data[cid]
        if not d:
            print(f"  note: results-{cid}/summary.csv missing — skipping '{label}'", file=sys.stderr)
            continue
        y = [d.get(bs, 0.0) for bs in bs_order]
        offs = (i - (n - 1) / 2) * width
        bars = plt.bar(x + offs, y, width, label=label, color=color, edgecolor="black", linewidth=0.4)
        plt.bar_label(bars, fmt="%.1f", fontsize=8, padding=2)

    plt.xticks(x, [b.upper() for b in bs_order])
    plt.xlabel("Block size")
    plt.ylabel("Steady-state network TX throughput (GB/s)")
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
