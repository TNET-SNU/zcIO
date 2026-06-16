#!/bin/bash
# all-in-one.sh (fig-7d) — run on stream5 (initiator). Fixed 256k random-read,
# 8 devices / 2 NICs, with the stream5 CPU-core count swept for each config:
#
#   x-axis = stream5 cores {1,2,4,8,12,15}
#   series = linux (zcopy off) / zcIO (zcopy on) / zcIO-MT (zcopy on, fio threads)
#
# rapids0 (target) stays at full cores. For each (config, cores): set the core
# count, reload mlx5 + reconfigure NICs, reconnect the 8 subsystems, run fio,
# measure steady RX.
#
# Results land in results-<config>/summary.csv (rows keyed by cores).
# Plot with:  python3 plot.py
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
export RAPIDS0
export RAPIDS0_DIR="${RAPIDS0_DIR:-/home/$(whoami)/zcio-ae-7d}"
SSHOPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5"
SSH="ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 $RAPIDS0"

# Override any of these from the env, e.g. to isolate the baseline:
#   CONFIGS=linux ./all-in-one.sh            (or use ./baseline-sweep.sh)
#   CONFIGS=linux CORE_SWEEP="8 4 2 1" SKIP_PREP=1 SKIP_RESTORE=1 ./all-in-one.sh
CONFIGS=(${CONFIGS:-linux zcIO-MT zcIO-MP spdk})   # spdk LAST: its residual degrades the next config's first point
# fio params are per-(config,cores) files: workload-<config>-<N>.fio (edit each).
# DESCENDING core list: connect once at full cores, then only ever offline more
# (this kernel can't multi-queue connect with CPUs already offlined).
CORE_SWEEP="${CORE_SWEEP:-15 12 8 4 2 1}"
MAXCORES="$(nproc --all)"

# ----- preflight ------------------------------------------------------
echo ">>> preflight: checking NOPASSWD sudo ..."
for s in workload.sh cpu-limit.sh stream5-net.sh; do
  sudo -n -l "$(pwd)/$s" >/dev/null 2>&1 || { echo "!! stream5 NOPASSWD missing for $s — run ../deploy.sh first"; exit 1; }
done
$SSH true 2>/dev/null \
    || { echo "!! cannot ssh $RAPIDS0 (passwordless) — run ../deploy.sh first"; exit 1; }

# ----- stage rapids0 target scripts (self-contained) ------------------
# Take ownership of the dst dir once (handles legacy root-owned files), then copy
# with plain user perms. Mirrors 9d's stage_to.
stage_to() {
    local host="$1" srcdir="$2" dstdir="$3"
    [ -d "$srcdir" ] || { echo "!! stage: $srcdir missing"; return 1; }
    ssh $SSHOPTS "$host" "sudo mkdir -p $dstdir && sudo chown -R \$(id -un):\$(id -gn) $dstdir" \
        || { echo "!! [$host] could not take ownership of $dstdir"; return 1; }
    tar czf - -C "$srcdir" . \
        | ssh $SSHOPTS "$host" "tar xzf - -C $dstdir && chmod +x $dstdir/*.sh 2>/dev/null; true"
}
echo ">>> staging target scripts to $RAPIDS0:$RAPIDS0_DIR"
stage_to "$RAPIDS0" "$(pwd)/rapids0" "$RAPIDS0_DIR" || { echo "!! staging failed"; exit 1; }

# ----- common target prep (rapids0, full cores) -----------------------
if [[ -z "${SKIP_PREP:-}" ]]; then
  echo
  echo ">>> [target rapids0] common prep: teardown -> net baseline -> buffer -> nvmet"
  $SSH sudo -n "$RAPIDS0_DIR/nvmet-9100-teardown.sh"  || { echo "!! teardown failed"; exit 1; }
  $SSH sudo -n "$RAPIDS0_DIR/target-net-config.sh" 9000 on off 0 || { echo "!! target net baseline failed"; exit 1; }
  $SSH sudo -n "$RAPIDS0_DIR/buffer.sh" || echo "!! buffer.sh failed (continuing)"
  sleep 3
  $SSH sudo -n "$RAPIDS0_DIR/nvmet-9100.sh" --no-ipsetup         || { echo "!! nvmet-9100 setup failed"; exit 1; }
  $SSH sudo -n "$RAPIDS0_DIR/cpu-governor.sh" performance || echo "!! cpu-governor performance failed (continuing)"
else
  echo ">>> SKIP_PREP set — skipping rapids0 common prep (target must already be up)"
fi

# ----- per config: online all cores, set NICs, connect once, sweep cores down --
for config in "${CONFIGS[@]}"; do
    echo
    echo "############################################################"
    echo "# config: $config   (fio=workload-$config-<N>.fio, cores: $CORE_SWEEP)"
    echo "############################################################"
    if ! "./case-$config.sh"; then
        echo "!! case-$config env setup FAILED — skipping config"
        continue
    fi
    # All cores ONLINE first — the NVMe/TCP multi-queue connect must happen at
    # full cores; the workload then offlines down to each core count for fio.
    ./cpu-limit.sh "$MAXCORES" || { echo "!! cpu online-all failed"; continue; }
    ./cpu-governor.sh performance >/dev/null 2>&1 || true
    ./buffer.sh >/dev/null 2>&1 || true
    ./stream5-net.sh           || { echo "!! stream5-net failed — skipping config"; continue; }
    if [[ "$config" == zcIO* ]]; then
        ./require-hwgro.sh || { echo "!! hw-gro not on — skipping config $config"; continue; }
    fi
    # spdk uses the SPDK userspace initiator (loops cores itself, no kernel
    # connect); the kernel configs connect once at full cores then offline.
    if [[ "$config" == spdk ]]; then
        ./workload-spdk.sh "results-$config" "$CORE_SWEEP" \
            || echo "!! workload-spdk failed (config=$config)"
    else
        ./workload.sh "results-$config" "$config" "$CORE_SWEEP" \
            || echo "!! workload failed (config=$config)"
    fi
done

# ----- combined report ------------------------------------------------
echo
echo "############################################################"
echo "# COMBINED: steady net RX (GB/s) by stream5 cores, 256k randread"
echo "############################################################"
CONFIG_NAMES="${CONFIGS[*]}" python3 - <<'PY'
import csv, os
names = os.environ["CONFIG_NAMES"].split()
data, order = {}, []
for c in names:
    p = f"results-{c}/summary.csv"
    if not os.path.exists(p): continue
    with open(p) as f:
        for row in csv.DictReader(f):
            k = row["cores"]
            if k not in data: data[k] = {}; order.append(k)
            data[k][c] = row["net_steady_GBps"]
order.sort(key=lambda x: int(x))
hdr = ["cores"] + list(names)
print("  ".join(f"{h:<10}" for h in hdr))
for k in order:
    print(f"{k:<10}" + "  ".join(f"{data[k].get(c,'-'):<10}" for c in names))
PY
echo
echo "Per-config raw results in results-<name>/  (${CONFIGS[*]})"
echo "Plot with:  python3 plot.py"

# ----- restore --------------------------------------------------------
if [[ -z "${SKIP_RESTORE:-}" ]]; then
  echo
  echo ">>> [initiator stream5] restoring: all cores online + net re-assert + zcopy off + TCP config"
  ./restore-tcp-config.sh || echo "!! restore-tcp-config reported an error"
  ./stream5-restore.sh || echo "!! stream5 restore reported an error"
  echo ">>> [target rapids0] resetting net baseline (MTU 9000, TSO on, pdu_align 0)"
  $SSH sudo -n "$RAPIDS0_DIR/target-net-config.sh" 9000 on off 0 || echo "!! rapids0 net reset reported an error"
else
  echo ">>> SKIP_RESTORE set — leaving cores limited / NICs as-is for the next run"
fi
echo "[all-in-one fig-7d] done."
