#!/usr/bin/env python3
# plot.py — draw the NVMe/TCP read-throughput sweep produced by all-in-one.sh.
#
# Reads results-cfg{1,2,3,4}/summary.csv (one row per block size, written by
# workload.sh) and plots peak network RX throughput vs block size, one line per
# config:
#
#   cfg1 -> 1500B MTU
#   cfg2 -> 9000B MTU
#   cfg3 -> TSO + 9000B MTU
#   cfg4 -> zcIO
#
# Usage:
#   python3 plot.py                       # reads ./results-cfgN, writes results-plot.png
#   python3 plot.py --results-dir DIR --out FILE.png [--metric net_peak_GBps]
#
# Requires matplotlib:  pip install --user matplotlib   (or: apt install python3-matplotlib)
import argparse, csv, os, sys

# config id -> (legend label, line style, color). Order = legend/plot order.
CONFIGS = [
    ("cfg1", "1500B MTU",       "o-", "#1f77b4"),
    ("cfg2", "9000B MTU",       "s-", "#ff7f0e"),
    ("cfg3", "TSO + 9000B MTU", "^-", "#2ca02c"),
    ("cfg4", "zcIO",            "D-", "#d62728"),
]

def bs_to_bytes(bs):
    """'128k' -> 131072, for sorting the x-axis by real block size."""
    s = bs.strip().lower()
    mult = 1
    if s.endswith("k"): mult, s = 1024, s[:-1]
    elif s.endswith("m"): mult, s = 1024 * 1024, s[:-1]
    try:    return int(float(s) * mult)
    except ValueError: return 0

def read_summary(path, metric):
    """Return {bs: value} from a summary.csv, or {} if absent/unreadable."""
    if not os.path.exists(path):
        return {}
    out = {}
    with open(path) as f:
        rdr = csv.DictReader(f)
        col = metric if metric in (rdr.fieldnames or []) else None
        if col is None:                         # fall back to a known throughput column
            for alt in ("net_steady_GBps", "net_peak_GBps", "net_GBps"):
                if alt in (rdr.fieldnames or []): col = alt; break
        if col is None:
            print(f"  warn: no throughput column in {path} (have {rdr.fieldnames})", file=sys.stderr)
            return {}
        for row in rdr:
            try:    out[row["bs"]] = float(row[col])
            except (KeyError, ValueError): pass
    return out

def main():
    ap = argparse.ArgumentParser(description="Plot the NVMe/TCP throughput sweep.")
    ap.add_argument("--results-dir", default=".", help="dir holding results-cfgN/ (default: .)")
    ap.add_argument("--out", default="results-plot.png", help="output image (default: results-plot.png)")
    ap.add_argument("--metric", default="net_steady_GBps", help="summary.csv column to plot")
    ap.add_argument("--title", default="NVMe/TCP read throughput vs block size (1-core target)")
    ap.add_argument("--ylabel", default="Steady-state network RX throughput (GB/s)", help="y-axis label")
    args = ap.parse_args()

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("ERROR: matplotlib not installed. Run:  pip install --user matplotlib")

    # Load each config's data; collect the union of block sizes (sorted by size).
    data, all_bs = {}, set()
    for cid, *_ in CONFIGS:
        d = read_summary(os.path.join(args.results_dir, f"results-{cid}", "summary.csv"), args.metric)
        data[cid] = d
        all_bs |= set(d)
    if not all_bs:
        sys.exit(f"ERROR: no summary.csv data found under {args.results_dir}/results-cfg*/")
    bs_order = sorted(all_bs, key=bs_to_bytes)
    x = list(range(len(bs_order)))

    plt.figure(figsize=(8, 5))
    plotted = 0
    for cid, label, style, color in CONFIGS:
        d = data[cid]
        if not d:
            print(f"  note: results-{cid}/summary.csv missing — skipping '{label}'", file=sys.stderr)
            continue
        y = [d.get(bs, float("nan")) for bs in bs_order]
        plt.plot(x, y, style, color=color, label=label, linewidth=2, markersize=7)
        plotted += 1
    if not plotted:
        sys.exit("ERROR: nothing to plot.")

    plt.xticks(x, [b.upper() for b in bs_order])
    plt.xlabel("Block size")
    plt.ylabel(args.ylabel)
    plt.title(args.title)
    plt.grid(True, linestyle="--", alpha=0.4)
    plt.legend(title="Config", loc="upper left")
    plt.ylim(bottom=0)
    plt.tight_layout()
    plt.savefig(args.out, dpi=150)
    # Also emit a vector PDF alongside the PNG (handy for papers/AE appendices).
    if args.out.lower().endswith(".png"):
        pdf = args.out[:-4] + ".pdf"
        plt.savefig(pdf)
        print(f"wrote {args.out} and {pdf}")
    else:
        print(f"wrote {args.out}")

if __name__ == "__main__":
    main()
