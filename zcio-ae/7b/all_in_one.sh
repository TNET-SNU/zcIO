#!/bin/bash
# all_in_one.sh (fig-7b) — run on stream5 (initiator). RANDOM-WRITE figure,
# fixed 256k, sweeping the TARGET (rapids0) CPU-core count. data flows
# stream5 -> rapids0, so this measures the TARGET's receive throughput as its core
# count scales. Line chart: x = rapids0 cores, one line per config.
#
# Role flip vs the read figures (7c/7d):
#   * stream5 is the SENDER -> nvme_pdu_align lives HERE (set-pdu-align.sh).
#   * rapids0 is the RECEIVER and is the core-swept side; throughput = summed
#     initiator TX (tx_bytes) over both NICs.
#
# Configs (CONFIGS):
#   linux    : pdu 0 ; rapids0 kernel nvmet + zcopy OFF ; fio processes
#   spdk     : pdu 0 ; rapids0 SPDK target (/opt/spdk_target.sh <cores>)
#   zcIO-MT  : pdu 2 ; rapids0 kernel nvmet + zcopy ON  ; fio threads (thread=1)
#   zcIO-MP  : pdu 2 ; rapids0 kernel nvmet + zcopy ON  ; fio processes
#
# Kernel-config sweep mechanics: connect the 8 subsystems ONCE at rapids0 FULL
# cores (multi-queue connect is happiest there), then only ever OFFLINE target
# cores (15 -> 12 -> 8 -> 4 -> 2 -> 1), re-pinning IRQs each step (no reload, no
# reconnect). SPDK fixes its core count at launch (core mask), so the SPDK config
# restarts the target and reconnects at each core count instead.
#
# Required kernels (boot manually first):
#   stream5 : 5.15.189-pduwin                 rapids0 : 6.11.0-target-zc-add-frozen+
#
# Results: results-<config>/summary.csv.  Plot:  python3 plot.py
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
rm -rf results-* 2>/dev/null || true   # fresh results each run (measure-point appends per point)

RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
export RAPIDS0
export RAPIDS0_DIR="${RAPIDS0_DIR:-/home/fast27/zcio-ae-7b}"
SSHOPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5"
SSH="ssh $SSHOPTS $RAPIDS0"

CONFIGS=(${CONFIGS:-linux zcIO-MT zcIO-MP spdk})   # spdk LAST: its residual degrades the next config's first point
CORE_SWEEP="${CORE_SWEEP:-15 12 8 4 2 1}"     # rapids0 cores, MUST be descending

# ----- preflight ------------------------------------------------------
echo ">>> preflight: NOPASSWD sudo (verify kernels first with: ./kernel-switch.sh write) ..."
sudo -n -l "$(pwd)/measure-point.sh" >/dev/null 2>&1 || { echo "!! stream5 NOPASSWD missing — run ../deploy.sh"; exit 1; }
$SSH true 2>/dev/null || { echo "!! cannot ssh $RAPIDS0 (passwordless) — run ../deploy.sh"; exit 1; }
echo "  cores: $CORE_SWEEP"

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

# ----- stream5 data-plane (full cores, once) --------------------------
# ----- ensure the host (SENDER) has all cores online ------------------
# This figure measures the receiver (target) overhead while the sender (this
# host) drives full-core traffic; only the TARGET is core-swept. A prior figure
# may have left host cores offline, which would silently make the sender the
# bottleneck and depress every config uniformly. Self-heal here.
off="$(cat /sys/devices/system/cpu/offline 2>/dev/null)"
if [ -n "$off" ]; then
    echo ">>> [initiator stream5] onlining offline cores ($off) — sender needs full cores"
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        id="${c##*/cpu}"; [ "$id" = 0 ] && continue
        [ -e "$c/online" ] && echo 1 | sudo tee "$c/online" >/dev/null
    done
fi
echo ">>> [initiator stream5] online cores: $(nproc)"

echo; echo ">>> [stream5] data plane: buffers + net (reload mlx5 + MTU 9000)"
# stream5 is the full-core SENDER (not the bottleneck), so no governor here — the
# performance governor is set on rapids0 (the core-limited bottleneck) per config.
./buffer.sh                   || echo "!! buffer.sh failed (continuing)"
./stream5-net.sh              || { echo "!! stream5 net setup failed"; exit 1; }

# ----- target setup helpers (rapids0) ---------------------------------
setup_kernel_target_full() {  # zcopy_on.sh|zcopy_off.sh  — set up kernel nvmet at FULL cores
    local zc="$1"
    echo ">>> [rapids0] kernel nvmet target @ FULL cores (connect happens here)"
    $SSH sudo -n "$RAPIDS0_DIR/cpu_on.sh"               >/dev/null 2>&1 || true
    $SSH sudo -n "$RAPIDS0_DIR/spdk-target-stop.sh"     || true
    $SSH sudo -n "$RAPIDS0_DIR/restore-tcp-config.sh"   || true
    $SSH sudo -n "$RAPIDS0_DIR/nvmet-9100-teardown.sh"  || { echo "!! teardown failed"; return 1; }
    $SSH sudo -n "$RAPIDS0_DIR/target-net.sh"           || { echo "!! target-net failed"; return 1; }
    $SSH sudo -n "$RAPIDS0_DIR/buffer.sh"               || true
    sleep 2
    $SSH sudo -n "$RAPIDS0_DIR/nvmet-9100.sh" --no-ipsetup || { echo "!! nvmet setup failed"; return 1; }
    $SSH sudo -n "$RAPIDS0_DIR/$zc"                     || true
    $SSH sudo -n "$RAPIDS0_DIR/cpu-governor.sh" performance || true
}
wait_nics_settle() {  # cpu-limit's mlx5 flap can drop a data NIC; wait for both back
    local i
    echo ">>> waiting for both data NICs to settle (ping) after cpu-limit ..."
    for i in $(seq 1 30); do
        ping -c1 -W1 10.3.95.10 >/dev/null 2>&1 && ping -c1 -W1 10.3.96.10 >/dev/null 2>&1 \
            && { echo "  both NICs up"; return 0; }
        sleep 1
    done
    echo "  !! WARN: both data NICs not pingable after 30s"
}
setup_spdk_target() {  # cores
    local cores="$1"
    echo ">>> [rapids0] SPDK target @ $cores core(s) (box cpu-limited to $cores, SPDK mask=$cores)"
    $SSH sudo -n "$RAPIDS0_DIR/cpu_on.sh"              >/dev/null 2>&1 || true   # full cores for clean mlx5 reload + nvmet teardown
    $SSH sudo -n "$RAPIDS0_DIR/nvmet-9100-teardown.sh" || true
    $SSH sudo -n "$RAPIDS0_DIR/target-net.sh"          || { echo "!! target-net failed"; return 1; }   # NICs up @ full cores
    $SSH sudo -n "$RAPIDS0_DIR/buffer.sh"              || true
    $SSH sudo -n "$RAPIDS0_DIR/set_tcp_config.sh"      || true
    # Confine the box to N cores BEFORE launching SPDK: the kernel TCP/softirq/NIC-IRQ
    # path is limited too (matching the kernel configs), AND the SPDK core mask
    # (cpu0..N-1) matches the online cores so DPDK EAL is happy. cpu-limit flaps
    # mlx5, so wait for the NICs to recover before SPDK binds its listeners.
    $SSH sudo -n "$RAPIDS0_DIR/cpu-limit.sh" "$cores"  || echo "!! cpu-limit failed"
    $SSH sudo -n "$RAPIDS0_DIR/set-irq-affinity.sh"    || true
    $SSH sudo -n "$RAPIDS0_DIR/cpu-governor.sh" performance || true
    wait_nics_settle
    $SSH sudo -n "$RAPIDS0_DIR/spdk-target-start.sh" "$cores" || { echo "!! spdk target start failed"; return 1; }
}

run_kernel_config() {  # config zcopy pdu
    local config="$1" zc="$2" pdu="$3" n
    setup_kernel_target_full "$zc" || return 1
    ./set-pdu-align.sh "$pdu"
    ./connect-targets.sh kernel || { echo "!! connect failed — skipping $config"; ./disconnect-targets.sh; return 1; }
    for n in $CORE_SWEEP; do
        echo "---------------- $config: rapids0 cores=$n ----------------"
        $SSH sudo -n "$RAPIDS0_DIR/cpu-limit.sh" "$n"       || echo "  !! cpu-limit $n failed"
        $SSH sudo -n "$RAPIDS0_DIR/set-irq-affinity.sh"     || true
        sleep 1
        ./measure-point.sh "results-$config" "$n" "workload-$config-$n.fio" cores \
            || echo "  !! measure $config cores=$n failed"
    done
    ./disconnect-targets.sh
}

run_spdk_config() {  # restart target + reconnect at each core count
    local n
    ./set-pdu-align.sh 0
    for n in $CORE_SWEEP; do
        echo "---------------- spdk: rapids0 cores=$n ----------------"
        setup_spdk_target "$n" || { echo "  !! spdk setup $n failed"; continue; }
        ./connect-targets.sh spdk || { echo "  !! connect failed cores=$n"; ./disconnect-targets.sh; continue; }
        ./measure-point.sh "results-spdk" "$n" "workload-spdk-$n.fio" cores \
            || echo "  !! measure spdk cores=$n failed"
        ./disconnect-targets.sh
    done
    $SSH sudo -n "$RAPIDS0_DIR/spdk-target-stop.sh" || true
}

# ----- per-config sweep -----------------------------------------------
for config in "${CONFIGS[@]}"; do
    echo; echo "############################################################"
    echo "# config: $config   (write, rapids0 core sweep: $CORE_SWEEP)"
    echo "############################################################"
    case "$config" in
        linux)    run_kernel_config linux   zcopy_off.sh 0 ;;
        zcIO-MT)  run_kernel_config zcIO-MT zcopy_on.sh  2 ;;
        zcIO-MP)  run_kernel_config zcIO-MP zcopy_on.sh  2 ;;
        spdk)     run_spdk_config ;;
        *)        echo "!! unknown config $config — skipping" ;;
    esac
done

# ----- combined report ------------------------------------------------
echo; echo "############################################################"
echo "# COMBINED: steady net TX (GB/s) by rapids0 core count"
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
            if k not in data: data[k] = {}; order.append(int(k))
            data[k][c] = row["net_steady_GBps"]
order = sorted(set(order))
hdr = ["cores"] + list(names)
print("  ".join(f"{h:<16}" for h in hdr))
for k in order:
    ks = str(k)
    print(f"{ks:<16}" + "  ".join(f"{data[ks].get(c,'-'):<16}" for c in names))
PY
echo; echo "Plot with:  python3 plot.py"

# ----- restore --------------------------------------------------------
echo; echo ">>> restore: stream5 net + pdu_align 0 ; rapids0 cores online + kernel nvmet baseline"
./set-pdu-align.sh 0 || true
./stream5-restore.sh || echo "!! stream5 restore reported an error"
$SSH sudo -n "$RAPIDS0_DIR/spdk-target-stop.sh"   || true
$SSH sudo -n "$RAPIDS0_DIR/restore-tcp-config.sh" || true
$SSH sudo -n "$RAPIDS0_DIR/target-restore.sh"     || echo "!! rapids0 target-restore reported an error"
echo "[all-in-one fig-7b] done."
