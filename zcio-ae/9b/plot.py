#!/usr/bin/env python3
# plot.py — fig-9b: UNet3D AU% vs online-core count, default vs zcIO.
#
#   Usage:  python3 plot.py [--results-dir results] [--configs default zcIO] [--out results-plot.png]
#
# Reads <results-dir>/coresweep-unet3d-<config>.csv (config,cores,read_threads,
# au_pct,samples_per_s), prints a table, and writes a line plot (AU% vs cores, one
# line per config) to results-plot.png (+ .pdf) in the current dir. Table-only if
# matplotlib is unavailable.
import csv, os, sys

def load(outdir, cfg):
    p = os.path.join(outdir, f"coresweep-unet3d-{cfg}.csv")
    if not os.path.exists(p):
        return {}
    d = {}
    for r in csv.DictReader(open(p)):
        try:
            d[int(r["cores"])] = float(r["au_pct"])
        except (ValueError, KeyError, TypeError):
            pass
    return d

def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--results-dir", default="results")      # where the coresweep-unet3d-<config>.csv files are
    ap.add_argument("--configs", nargs="+", default=["default", "zcIO"])
    ap.add_argument("--out", default="results-plot.png")
    args = ap.parse_args()
    outdir = args.results_dir
    configs = args.configs

    data = {c: load(outdir, c) for c in configs}
    data = {c: v for c, v in data.items() if v}
    if not data:
        print(f"!! no coresweep-unet3d-*.csv in {outdir}/"); return 1

    cores = sorted({n for v in data.values() for n in v})
    present = [c for c in configs if c in data]

    # ---- table ----
    print("  ".join(f"{h:<10}" for h in ["cores"] + present) + "   (AU %)")
    print("-" * (12 * (len(present) + 1)))
    for n in cores:
        row = [str(n)] + [(f"{data[c][n]:.2f}" if n in data[c] else "-") for c in present]
        print("  ".join(f"{x:<10}" for x in row))

    # ---- plot ----
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as e:
        print(f"\n(matplotlib unavailable: {e} — table only)")
        return 0

    colors = {"default": "#9aa0a6", "zcIO": "#1a73e8"}
    fig, ax = plt.subplots(figsize=(7, 4.5))
    for c in present:
        xs = [n for n in cores if n in data[c]]
        ys = [data[c][n] for n in xs]
        ax.plot(xs, ys, marker="o", label=c, color=colors.get(c))
        for x, y in zip(xs, ys):
            ax.annotate(f"{y:.0f}", (x, y), textcoords="offset points",
                        xytext=(0, 6), ha="center", fontsize=8)
    ax.axhline(90, ls="--", color="red", alpha=0.5, lw=1)
    ax.text(cores[-1], 90, " AU 90% target", color="red", va="bottom", ha="right", fontsize=8)
    ax.set_xlabel("Online CPU cores")
    ax.set_ylabel("Accelerator Utilization AU (%)")
    ax.set_title("fig-9b — UNet3D (8 accel) AU% vs CPU cores: default vs zcIO")
    ax.set_xticks(cores)
    ax.set_ylim(0, 105)
    ax.grid(alpha=0.3)
    ax.legend()
    fig.tight_layout()
    out = args.out
    fig.savefig(out, dpi=150)
    pdf = os.path.splitext(out)[0] + ".pdf"
    fig.savefig(pdf)
    print(f"\n-> {out}  /  {pdf}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
