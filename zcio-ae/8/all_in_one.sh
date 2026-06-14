#!/bin/bash
# all_in_one.sh — run on stream5 (initiator). NVMe/TCP read sweep over ONE NIC
# pair and the 4 subsystems on it (workload.sh), measured steady-state, across
# the 4 network configs:
#
#   [stage]               push rapids0/ target scripts to $RAPIDS0_DIR (self-contained)
#   [initiator stream5]   buffer.sh -> stream5-net.sh
#   [common prep rapids0] teardown -> 1 CPU core -> settle -> net baseline ->
#                         buffer.sh -> nvmet-9100 -> governor performance
#   for each config N:    caseN.sh (env) -> workload.sh (4-dev steady sweep)
#   [report]              combined GB/s table   [restore] rapids0 baseline
#
#   config | E2E MTU | target TSO | target GSO | nvme_pdu_align
#     1=1500/off/off/0  2=9000/off/off/0  3=9000/on/off/0  4=9000/on/off/1
#   (target pinned to 1 CPU core for every config)
#
# Results land in results-cfgN/.  Plot with:  python3 plot.py
#
# Needs the one-time top-level env setup ( ../deploy.sh : passwordless SSH +
# NOPASSWD sudo). This figure stages its OWN rapids0 scripts each run, so there
# is no per-figure deploy step.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
# Unified AE staging dir on the target (override via env if needed). Exported so
# the case/env-config children resolve the SAME path.
export RAPIDS0
export RAPIDS0_DIR="${RAPIDS0_DIR:-/home/fast27/zcio-ae-8}"
SSHOPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5"
SSH="ssh $SSHOPTS $RAPIDS0"

CONFIGS=(1 2 3 4)

# ----- preflight: NOPASSWD sudo on stream5 (from ../deploy.sh) ---------
echo ">>> preflight: checking NOPASSWD sudo on stream5 ..."
sudo -n -l "$(pwd)/workload.sh" >/dev/null 2>&1 \
    || { echo "!! stream5 NOPASSWD missing — run ../deploy.sh first"; exit 1; }
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

# ----- ensure the host (RECEIVER) has all cores online ----------------
# This figure measures sender-side (target) overhead while the receiver (this
# host) is given sufficient cores; only the TARGET is pinned to 1 core. A prior
# figure may have left host cores offline, which would silently make the
# initiator the bottleneck and depress every config uniformly. Self-heal here.
off="$(cat /sys/devices/system/cpu/offline 2>/dev/null)"
if [ -n "$off" ]; then
    echo ">>> [initiator stream5] onlining offline cores ($off) — receiver needs full cores"
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        id="${c##*/cpu}"; [ "$id" = 0 ] && continue
        [ -e "$c/online" ] && echo 1 | sudo tee "$c/online" >/dev/null
    done
fi
echo ">>> [initiator stream5] online cores: $(nproc)"

# ----- initiator (stream5) data NICs FIRST ----------------------------
echo
echo ">>> [initiator stream5] buffer.sh (64MiB socket buffers + rings 8192)"
./buffer.sh || echo "!! stream5 buffer.sh failed (continuing)"
echo ">>> [initiator stream5] configuring data NICs (ens2np0=10.3.95.5, ens3np0=10.3.96.5)"
./stream5-net.sh || { echo "!! stream5 net setup failed"; exit 1; }

# ----- common target prep (once) --------------------------------------
echo
echo ">>> [target rapids0] common prep: teardown -> 1 CPU core -> settle -> nvmet"
$SSH sudo -n "$RAPIDS0_DIR/nvmet-9100-teardown.sh"  || { echo "!! teardown failed"; exit 1; }
$SSH sudo -n "$RAPIDS0_DIR/cpu_off.sh"              || { echo "!! cpu_off failed"; exit 1; }

echo ">>> [target rapids0] waiting for ens17np0/ens19np0 to settle after CPU offline ..."
$SSH 'for i in $(seq 1 30); do
        ok=1
        for n in ens17np0 ens19np0; do
          [ -e /sys/class/net/$n ] || ok=0
          [ "$(cat /sys/class/net/$n/operstate 2>/dev/null)" = up ] || ok=0
        done
        [ $ok -eq 1 ] && { echo "  both NICs up after ${i}s"; break; }
        sleep 1
      done'
sleep 3

$SSH sudo -n "$RAPIDS0_DIR/target-net-config.sh" 9000 on off 0 || { echo "!! target net baseline failed"; exit 1; }
echo ">>> [target rapids0] buffer.sh (rings 8192 + socket buffers)"
$SSH sudo -n "$RAPIDS0_DIR/buffer.sh" || echo "!! buffer.sh failed (continuing)"
sleep 3
$SSH sudo -n "$RAPIDS0_DIR/nvmet-9100.sh" --no-ipsetup         || { echo "!! nvmet-9100 setup failed"; exit 1; }
echo ">>> [target rapids0] CPU governor -> performance"
$SSH sudo -n "$RAPIDS0_DIR/cpu-governor.sh" performance || echo "!! cpu-governor performance failed (continuing)"

# ----- per-config sweep -----------------------------------------------
for n in "${CONFIGS[@]}"; do
    echo
    echo "############################################################"
    echo "# config $n  (4 devices / single NIC)"
    echo "############################################################"
    if ! "./case$n.sh"; then
        echo "!! case$n env setup FAILED — skipping"
        continue
    fi
    ./workload.sh "results-cfg$n"
done

# ----- combined report ------------------------------------------------
echo
echo "############################################################"
echo "# COMBINED (4 dev/1 NIC): steady net RX throughput (GB/s) by block size"
echo "############################################################"
python3 - <<'PY'
import csv, os
configs = ["cfg1","cfg2","cfg3","cfg4"]
labels  = {"cfg1":"1500/tso-off/pa0", "cfg2":"9000/tso-off/pa0",
           "cfg3":"9000/tso-on/pa0",  "cfg4":"9000/tso-on/pa1"}
data, order = {}, []
for c in configs:
    p = f"results-{c}/summary.csv"
    if not os.path.exists(p): continue
    with open(p) as f:
        for row in csv.DictReader(f):
            bs = row["bs"]
            if bs not in data: data[bs] = {}; order.append(bs)
            data[bs][c] = row["net_steady_GBps"]
hdr = ["bs"] + [f"{c}({labels[c]})" for c in configs]
print("  ".join(f"{h:<22}" for h in hdr))
for bs in order:
    print(f"{bs:<22}" + "  ".join(f"{data[bs].get(c,'-'):<22}" for c in configs))
PY
echo
echo "Per-config raw results in results-cfg{1,2,3,4}/"
echo "Plot with:  python3 plot.py"

# ----- restore rapids0 ------------------------------------------------
echo
echo ">>> [target rapids0] restoring: all cores online + mlx5_core reload + nvmet-9100"
$SSH sudo -n "$RAPIDS0_DIR/target-restore.sh" \
    || echo "!! rapids0 restore reported an error — check it (sudo $RAPIDS0_DIR/target-restore.sh)"
echo "[all_in_one] done."
