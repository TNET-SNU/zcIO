#!/bin/bash
# all_in_one.sh (fig-7a) — run on stream5 (initiator). RANDOM-WRITE figure:
# data flows stream5 -> rapids0, so this measures the TARGET's receive throughput
# with the TARGET (rapids0) limited to 1 CPU core. Bar chart over block size.
#
# Role flip vs the read figures (7c/7d):
#   * stream5 is the SENDER -> nvme_pdu_align lives HERE (net.ipv4.nvme_pdu_align,
#     5.15.189-pduwin kernel) via set-pdu-align.sh.
#   * rapids0 is the RECEIVER -> zero-copy receive (zcopy) lives THERE, and the
#     target is the core-limited bottleneck (1 core for this figure).
#   * throughput = summed initiator TX (tx_bytes) over both NICs.
#
# Configs (CONFIGS):
#   linux : stream5 pdu_align 0 ; rapids0 kernel nvmet + zcopy OFF
#   spdk  : stream5 pdu_align 0 ; rapids0 SPDK target (/opt/spdk_target.sh 1)
#   zcIO  : stream5 pdu_align 2 ; rapids0 kernel nvmet + zcopy ON
#
# Required kernels (boot manually first; ./reboot-to-kernel.sh helps):
#   stream5 : 5.15.189-pduwin                 rapids0 : 6.11.0-target-zc-add-frozen+
#
# Results land in results-<config>/.  Plot:  python3 plot.py
#
# Needs the one-time top-level env setup ( ../deploy.sh : passwordless SSH +
# NOPASSWD sudo). This figure stages its OWN rapids0 scripts each run, so there
# is no per-figure deploy step.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
rm -rf results-* 2>/dev/null || true   # fresh results each run (measure-point appends per point)

RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
export RAPIDS0
export RAPIDS0_DIR="${RAPIDS0_DIR:-/home/$(whoami)/zcio-ae-7a}"
SSHOPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5"
SSH="ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 $RAPIDS0"

CONFIGS=(${CONFIGS:-linux zcIO spdk})              # spdk LAST: its residual degrades the next config's first point
BS_LIST="${BS_LIST:-4k 16k 32k 64k 128k 256k 512k}"
TARGET_CORES="${TARGET_CORES:-1}"     # rapids0 is pinned to this many cores

# ----- preflight ------------------------------------------------------
echo ">>> preflight: NOPASSWD sudo (verify kernels first with: ./kernel-switch.sh write) ..."
sudo -n -l "$(pwd)/measure-point.sh" >/dev/null 2>&1 || { echo "!! stream5 NOPASSWD missing — run ../deploy.sh"; exit 1; }
$SSH true 2>/dev/null || { echo "!! cannot ssh $RAPIDS0 (passwordless) — run ../deploy.sh"; exit 1; }

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

# ----- fresh-SLC clean start: nvme-format the 9100 PROs, settle, and VERIFY clean
# BEFORE the run (SKIP_FORMAT=1 to skip; FMT_IDLE_SECS to tune the settle wait).
echo; echo ">>> [rapids0] format-9100.sh — fresh-SLC clean start (format + settle + verify)"
$SSH sudo -n "$RAPIDS0_DIR/format-9100.sh" || { echo "!! format-9100 failed — aborting (devices not clean)"; exit 1; }

# ----- stream5 data-plane (full cores, once) --------------------------
echo; echo ">>> [stream5] data plane: buffers + net (reload mlx5 + MTU 9000)"
# ----- ensure the host (SENDER) has all cores online ------------------
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
# stream5 is the full-core SENDER (not the bottleneck), so no governor here — the
# performance governor is set on rapids0 (the core-limited bottleneck) per config.
./buffer.sh                   || echo "!! buffer.sh failed (continuing)"
./stream5-net.sh              || { echo "!! stream5 net setup failed"; exit 1; }

# ----- target setup helpers (rapids0) ---------------------------------
setup_kernel_target() {  # zcopy_on.sh|zcopy_off.sh
    local zc="$1"
    echo ">>> [rapids0] kernel nvmet target @ full cores -> limit to $TARGET_CORES"
    $SSH sudo -n "$RAPIDS0_DIR/cpu_on.sh"               >/dev/null 2>&1 || true   # all cores online for setup
    $SSH sudo -n "$RAPIDS0_DIR/spdk-target-stop.sh"     || true                   # rebind NVMe to kernel if SPDK ran
    $SSH sudo -n "$RAPIDS0_DIR/restore-tcp-config.sh"   || true                   # undo SPDK tcp tuning if any
    $SSH sudo -n "$RAPIDS0_DIR/nvmet-9100-teardown.sh"  || { echo "!! teardown failed"; return 1; }
    $SSH sudo -n "$RAPIDS0_DIR/target-net.sh"           || { echo "!! target-net failed"; return 1; }
    $SSH sudo -n "$RAPIDS0_DIR/buffer.sh"               || true
    sleep 2
    $SSH sudo -n "$RAPIDS0_DIR/nvmet-9100.sh" --no-ipsetup || { echo "!! nvmet setup failed"; return 1; }
    $SSH sudo -n "$RAPIDS0_DIR/$zc"                     || true
    $SSH sudo -n "$RAPIDS0_DIR/cpu-limit.sh" "$TARGET_CORES" || echo "!! cpu-limit failed"
    #$SSH sudo -n "$RAPIDS0_DIR/set-irq-affinity.sh"     || true   # disabled: keep rapids0 irqbalance on
    $SSH sudo -n "$RAPIDS0_DIR/cpu-governor.sh" performance || true
}
setup_spdk_target() {  # cores
    local cores="$1"
    echo ">>> [rapids0] SPDK target @ $cores core(s) (core mask)"
    $SSH sudo -n "$RAPIDS0_DIR/cpu_on.sh"              >/dev/null 2>&1 || true   # cores online for the mask
    $SSH sudo -n "$RAPIDS0_DIR/nvmet-9100-teardown.sh" || true                  # drop kernel nvmet
    $SSH sudo -n "$RAPIDS0_DIR/target-net.sh"          || { echo "!! target-net failed"; return 1; }
    $SSH sudo -n "$RAPIDS0_DIR/buffer.sh"              || true
    $SSH sudo -n "$RAPIDS0_DIR/set_tcp_config.sh"      || true
    # Confine the whole box to N cores BEFORE launching SPDK, so the kernel
    # TCP/softirq/NIC-IRQ path is limited too (matching the kernel configs) AND so
    # we don't offline cores while nvmf_tgt is mid-DPDK-init (which kills it). The
    # SPDK core mask (cpu0..N-1) matches the cores left online.
    $SSH sudo -n "$RAPIDS0_DIR/cpu-limit.sh" "$cores"  || echo "!! cpu-limit failed"
    #$SSH sudo -n "$RAPIDS0_DIR/set-irq-affinity.sh"    || true   # disabled: keep rapids0 irqbalance on
    $SSH sudo -n "$RAPIDS0_DIR/cpu-governor.sh" performance || true
    # cpu-limit flaps mlx5; wait for the data NIC to recover before SPDK binds its listener
    echo ">>> waiting for data NIC (.95.10) to settle after cpu-limit ..."
    for _i in $(seq 1 30); do ping -c1 -W1 10.3.95.10 >/dev/null 2>&1 && break; sleep 1; done
    $SSH sudo -n "$RAPIDS0_DIR/spdk-target-start.sh" "$cores" || { echo "!! spdk target start failed"; return 1; }
}

# ----- per-config sweep -----------------------------------------------
for config in "${CONFIGS[@]}"; do
    echo; echo "############################################################"
    echo "# config: $config   (write, rapids0 ${TARGET_CORES}-core, fio=workload-$config-<bs>.fio)"
    echo "############################################################"
    case "$config" in
        linux) setup_kernel_target zcopy_off.sh || continue; ./set-pdu-align.sh 0; mode=kernel ;;
        zcIO)  setup_kernel_target zcopy_on.sh  || continue; ./set-pdu-align.sh 2; mode=kernel ;;
        spdk)  setup_spdk_target "$TARGET_CORES" || continue; ./set-pdu-align.sh 0; mode=spdk ;;
        *)     echo "!! unknown config $config — skipping"; continue ;;
    esac

    ./connect-targets.sh "$mode" || { echo "!! connect failed — skipping $config"; ./disconnect-targets.sh; continue; }
    for bs in $BS_LIST; do
        ./measure-point.sh "results-$config" "$bs" "workload-$config-$bs.fio" bs \
            || echo "!! measure $config bs=$bs failed"
    done
    if [[ -n "${KEEP_UP:-}" ]]; then
        echo ">>> KEEP_UP set — leaving target + nvme connections up (no disconnect / no spdk-stop)"
    else
        ./disconnect-targets.sh
        [[ "$config" == spdk ]] && { $SSH sudo -n "$RAPIDS0_DIR/spdk-target-stop.sh" || true; }
    fi
done

# ----- combined report ------------------------------------------------
echo; echo "############################################################"
echo "# COMBINED (rapids0 ${TARGET_CORES}-core): steady net TX (GB/s) by block size"
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
echo; echo "Plot with:  python3 plot.py"

# ----- restore --------------------------------------------------------
if [[ -n "${KEEP_UP:-}" ]]; then
    echo; echo ">>> KEEP_UP set — skipping restore. Target/SPDK + nvme connections left up for manual fio."
    echo "    connected NVMe-oF devices (point your fio here):"
    for b in /sys/block/nvme*n*; do
        bn="$(basename "$b")"; [[ "$bn" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        [[ "$(cat "$b/device/transport" 2>/dev/null)" == tcp ]] && echo "      /dev/$bn"
    done
    echo "    when done, tear down with:"
    echo "      ./disconnect-targets.sh"
    echo "      $SSH sudo -n $RAPIDS0_DIR/spdk-target-stop.sh"
    echo "      ./stream5-restore.sh ; $SSH sudo -n $RAPIDS0_DIR/target-restore.sh"
else
    echo; echo ">>> restore: stream5 net + pdu_align 0 ; rapids0 cores online + kernel nvmet baseline"
    ./set-pdu-align.sh 0 || true
    ./stream5-restore.sh || echo "!! stream5 restore reported an error"
    $SSH sudo -n "$RAPIDS0_DIR/spdk-target-stop.sh"   || true
    $SSH sudo -n "$RAPIDS0_DIR/restore-tcp-config.sh" || true
    $SSH sudo -n "$RAPIDS0_DIR/target-restore.sh"     || echo "!! rapids0 target-restore reported an error"
fi
echo "[all-in-one fig-7a] done."
