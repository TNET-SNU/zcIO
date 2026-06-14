#!/usr/bin/env python3
# plot.py (fig-7d) — line chart of steady NVMe/TCP throughput vs stream5 core
# count (256k random read), one line per config:
#
#   linux    (zero-copy off)
#   zcIO     (zero-copy on)
#   zcIO-MT  (zero-copy on, fio threads)
#
# Reads results-<config>/summary.csv (column net_steady_GBps, rows keyed by
# 'cores') and writes results-plot.png + results-plot.pdf.
#
# Usage:  python3 plot.py [--results-dir DIR] [--out FILE.png] [--metric COL]
import argparse, csv, os, sys

# results dir name -> (legend label, line style, color).
CONFIGS = [
    ("linux",   "linux",   "o-", "#1f77b4"),
    ("spdk",    "SPDK",    "D-", "#9467bd"),
    ("zcIO-MT", "zcIO-MT", "^-", "#2ca02c"),
    ("zcIO-MP", "zcIO-MP", "s-", "#d62728"),
]

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
            try:    out[int(row["cores"])] = float(row[col])
            except (KeyError, ValueError): pass
    return out

def main():
    ap = argparse.ArgumentParser(description="fig-7d cores sweep line chart")
    ap.add_argument("--results-dir", default=".")
    ap.add_argument("--out", default="results-plot.png")
    ap.add_argument("--metric", default="net_steady_GBps")
    ap.add_argument("--title", default="NVMe/TCP 256k random read vs stream5 cores")
    args = ap.parse_args()

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("ERROR: matplotlib not installed. Run:  pip install --user matplotlib")

    data, all_cores = {}, set()
    for cid, *_ in CONFIGS:
        d = read_summary(os.path.join(args.results_dir, f"results-{cid}", "summary.csv"), args.metric)
        data[cid] = d; all_cores |= set(d)
    if not all_cores:
        sys.exit(f"ERROR: no summary.csv data under {args.results_dir}/results-*/")

    xs = sorted(all_cores)                      # core counts on the x-axis
    plt.figure(figsize=(8, 5))
    plotted = 0
    for cid, label, style, color in CONFIGS:
        d = data[cid]
        if not d:
            print(f"  note: results-{cid}/summary.csv missing — skipping '{label}'", file=sys.stderr)
            continue
        x = [c for c in xs if c in d]
        y = [d[c] for c in x]
        plt.plot(x, y, style, color=color, label=label, linewidth=2, markersize=7)
        plotted += 1
    if not plotted:
        sys.exit("ERROR: nothing to plot.")

    plt.xticks(xs, [str(c) for c in xs])
    plt.xlabel("stream5 CPU cores")
    plt.ylabel("Steady-state network RX throughput (GB/s)")
    plt.title(args.title)
    plt.grid(True, linestyle="--", alpha=0.4)
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
