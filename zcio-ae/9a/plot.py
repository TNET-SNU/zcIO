#!/usr/bin/env python3
# plot.py — fig-9a combined report: default vs zcIO peak incoming Gbps.
#
#   Usage:  python3 plot.py [--results-dir results] [--configs default zcIO] [--out results-plot.png]
#
# Reads <results-dir>/<workload>-<config>.csv (header: workload,config,peak_incoming_gbps)
# for each workload, prints a table (default | zcIO | speedup) and writes a grouped
# bar chart to results-plot.png (+ .pdf) in the current dir. Table-only if matplotlib
# is missing.
import csv, os, sys

WL_ORDER = ["unet3d", "llama3", "cosmoflow"]   # canonical x-axis order
WL_LABEL = {"unet3d": "UNet3D", "llama3": "Llama3 (load)", "cosmoflow": "CosmoFlow"}

def read_peak(outdir, wl, cfg):
    p = os.path.join(outdir, f"{wl}-{cfg}.csv")
    if not os.path.exists(p):
        return None
    try:
        for r in csv.DictReader(open(p)):
            return float(r.get("peak_incoming_gbps"))
    except Exception:
        return None
    return None

def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--results-dir", default="results")      # where the <workload>-<config>.csv files are
    ap.add_argument("--configs", nargs="+", default=["default", "zcIO"])
    ap.add_argument("--out", default="results-plot.png")
    args = ap.parse_args()
    outdir = args.results_dir
    configs = args.configs

    # discover workloads present, keep canonical order then any extras
    present = [w for w in WL_ORDER
               if any(os.path.exists(os.path.join(outdir, f"{w}-{c}.csv")) for c in configs)]
    if not present:
        print(f"!! no <workload>-<config>.csv found in {outdir}/"); return 1

    data = {w: {c: read_peak(outdir, w, c) for c in configs} for w in present}

    # ---- table ----
    base, zc = (configs + [None, None])[:2]
    hdr = ["workload"] + configs + (["speedup"] if len(configs) == 2 else [])
    print("  ".join(f"{h:<14}" for h in hdr) + "   (peak incoming Gbps)")
    print("-" * (16 * len(hdr)))
    for w in present:
        row = [WL_LABEL.get(w, w)]
        for c in configs:
            v = data[w][c]
            row.append("-" if v is None else f"{v:.2f}")
        if len(configs) == 2:
            a, b = data[w][base], data[w][zc]
            row.append(f"{b/a:.2f}x" if (a and b) else "-")
        print("  ".join(f"{x:<14}" for x in row))

    # ---- plot ----
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as e:
        print(f"\n(matplotlib unavailable: {e} — table only, no PNG)")
        return 0

    n = len(present)
    x = range(n)
    width = 0.8 / max(1, len(configs))
    colors = {"default": "#9aa0a6", "zcIO": "#1a73e8"}
    fig, ax = plt.subplots(figsize=(1.8 * n + 2, 4.5))
    for i, c in enumerate(configs):
        vals = [data[w][c] or 0 for w in present]
        xs = [xi + i * width - (len(configs) - 1) * width / 2 for xi in x]
        bars = ax.bar(xs, vals, width, label=c, color=colors.get(c, None))
        for b, v in zip(bars, vals):
            if v:
                ax.text(b.get_x() + b.get_width() / 2, v, f"{v:.1f}",
                        ha="center", va="bottom", fontsize=8)
    # speedup annotation above the zcIO bar
    if len(configs) == 2:
        for xi, w in zip(x, present):
            a, b = data[w][base], data[w][zc]
            if a and b:
                ax.text(xi, max(a, b) * 1.08, f"{b/a:.2f}x",
                        ha="center", va="bottom", fontsize=9, fontweight="bold",
                        color=colors.get(zc, "black"))
    ax.set_xticks(list(x))
    ax.set_xticklabels([WL_LABEL.get(w, w) for w in present])
    ax.set_ylabel("Peak incoming bandwidth (Gbps)")
    ax.set_title("fig-9a — MLPerf Storage single-core: default vs zcIO")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    ax.set_ylim(top=ax.get_ylim()[1] * 1.18)
    fig.tight_layout()
    out = args.out
    fig.savefig(out, dpi=150)
    pdf = os.path.splitext(out)[0] + ".pdf"
    fig.savefig(pdf)
    print(f"\n-> {out}  /  {pdf}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
