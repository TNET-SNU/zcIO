#!/bin/bash
# all-in-one.sh (fig-7c) — run on stream5 (initiator). Same 8-device / 2-NIC read
# sweep as fig-8, but the bottleneck is moved to the INITIATOR:
#
#   * rapids0 (target) is NOT core-limited (stays at full cores).
#   * stream5 (initiator) IS limited to 1 CPU core.
#   * named configs (add more to CONFIGS, e.g. spdk, with a case-<name>.sh):
#       linux: MTU 9000 / TSO on / pdu_align 0 + zcopy OFF
#       zcIO : MTU 9000 / TSO on / pdu_align 2 + zcopy ON
#
# Flow:
#   [initiator stream5] cpu-limit 1 core -> settle -> governor -> buffer -> net
#   [common prep rapids0] teardown -> net baseline -> buffer -> nvmet -> governor
#   for name in CONFIGS:  case-<name>.sh -> workload.sh -> results-<name>/
#   [report] bar table   [restore] stream5 cores/mlx5/net + rapids0 net baseline
#
# Results land in results-<name>/.  Plot with:  python3 plot.py
# Requires the NOPASSWD sudoers installed by deploy.sh on both hosts.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
export RAPIDS0
export RAPIDS0_DIR="${RAPIDS0_DIR:-/home/$(whoami)/zcio-ae-7c}"
SSHOPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5"
SSH="ssh $SSHOPTS $RAPIDS0"

# Config names -> case-<name>.sh and results-<name>/. Add "spdk" here + a
# case-spdk.sh to include it.
CONFIGS=(${CONFIGS:-linux zcIO spdk})              # spdk LAST: its residual degrades the next config's first point

# ----- preflight ------------------------------------------------------
echo ">>> preflight: checking NOPASSWD sudo ..."
sudo -n -l "$(pwd)/workload.sh" >/dev/null 2>&1 \
    || { echo "!! stream5 NOPASSWD missing for workload.sh — run ../deploy.sh first"; exit 1; }
sudo -n -l "$(pwd)/cpu-limit-1core.sh" >/dev/null 2>&1 \
    || { echo "!! stream5 NOPASSWD missing for cpu-limit-1core.sh — run ../deploy.sh first"; exit 1; }
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

# ----- initiator (stream5): limit to 1 core, then bring up the data plane ---
echo
echo ">>> [initiator stream5] limiting to 1 CPU core (mlx5 NICs may flap)"
./cpu-limit-1core.sh || { echo "!! stream5 cpu-limit failed"; exit 1; }
echo ">>> [initiator stream5] waiting for ens2np0/ens3np0 to settle ..."
for i in $(seq 1 30); do
  ok=1
  for n in ens2np0 ens3np0; do
    [ -e "/sys/class/net/$n" ] || ok=0
    [ "$(cat /sys/class/net/$n/operstate 2>/dev/null)" = up ] || ok=0
  done
  [ "$ok" -eq 1 ] && { echo "  both NICs up after ${i}s"; break; }
  sleep 1
done
sleep 2
echo ">>> [initiator stream5] CPU governor -> performance"
./cpu-governor.sh performance || echo "!! stream5 cpu-governor failed (continuing)"
echo ">>> [initiator stream5] buffer.sh (64MiB socket buffers)"
./buffer.sh || echo "!! stream5 buffer.sh failed (continuing)"
echo ">>> [initiator stream5] stream5-net.sh (reload mlx5 + rings + hw-gro-first recipe)"
./stream5-net.sh || { echo "!! stream5 net setup failed"; exit 1; }
echo ">>> [initiator stream5] set-irq-affinity (pin NIC IRQs to online cores + stop irqbalance)"
./set-irq-affinity.sh >/dev/null 2>&1 || echo "!! set-irq-affinity failed (continuing)"

# ----- common target prep (rapids0, NO core limit) --------------------
echo
echo ">>> [target rapids0] common prep: teardown -> net baseline -> buffer -> nvmet"
$SSH sudo -n "$RAPIDS0_DIR/nvmet-9100-teardown.sh"  || { echo "!! teardown failed"; exit 1; }
$SSH sudo -n "$RAPIDS0_DIR/target-net-config.sh" 9000 on off 0 || { echo "!! target net baseline failed"; exit 1; }
echo ">>> [target rapids0] buffer.sh (rings 8192 + socket buffers)"
$SSH sudo -n "$RAPIDS0_DIR/buffer.sh" || echo "!! buffer.sh failed (continuing)"
sleep 3
$SSH sudo -n "$RAPIDS0_DIR/nvmet-9100.sh" --no-ipsetup         || { echo "!! nvmet-9100 setup failed"; exit 1; }
echo ">>> [target rapids0] CPU governor -> performance"
$SSH sudo -n "$RAPIDS0_DIR/cpu-governor.sh" performance || echo "!! cpu-governor performance failed (continuing)"

# ----- per-config sweep -----------------------------------------------
for name in "${CONFIGS[@]}"; do
    echo
    echo "############################################################"
    echo "# config: $name  — 8 dev / 2 NIC, stream5 1-core"
    echo "############################################################"
    if ! "./case-$name.sh"; then
        echo "!! case-$name env setup FAILED — skipping"
        continue
    fi
    # spdk uses the SPDK userspace initiator (different workload); others use the
    # kernel nvme-tcp workload.
    if [[ "$name" == spdk ]]; then
        ./workload-spdk.sh "results-$name"          # uses workload-spdk-<bs>.fio
    else
        ./workload.sh "results-$name" "$name"        # uses workload-<name>-<bs>.fio
    fi
done

# ----- combined report ------------------------------------------------
echo
echo "############################################################"
echo "# COMBINED (stream5 1-core): steady net RX throughput (GB/s) by block size"
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
            bs = row["bs"]
            if bs not in data: data[bs] = {}; order.append(bs)
            data[bs][c] = row["net_steady_GBps"]
hdr = ["bs"] + list(names)
print("  ".join(f"{h:<16}" for h in hdr))
for bs in order:
    print(f"{bs:<16}" + "  ".join(f"{data[bs].get(c,'-'):<16}" for c in names))
PY
echo
echo "Per-config raw results in results-<name>/  (${CONFIGS[*]})"
echo "Plot with:  python3 plot.py"

# ----- restore --------------------------------------------------------
echo
echo ">>> [initiator stream5] restoring: all cores online + net re-assert + zcopy off + TCP config"
./restore-tcp-config.sh || echo "!! restore-tcp-config reported an error"
./stream5-restore.sh || echo "!! stream5 restore reported an error — check it (sudo ./stream5-restore.sh)"
echo ">>> [target rapids0] resetting net baseline (MTU 9000, TSO on, pdu_align 0)"
$SSH sudo -n "$RAPIDS0_DIR/target-net-config.sh" 9000 on off 0 \
    || echo "!! rapids0 net reset reported an error"
echo "[all-in-one fig-7c] done."
