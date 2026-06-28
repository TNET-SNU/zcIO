#!/bin/bash
# all_in_one.sh (fig-7b) — run on stream5 (initiator #1). RANDOM-WRITE figure,
# fixed 256k, sweeping the TARGET (rapids0) CPU-core count. Line chart: x = rapids0
# cores, one line per config.
#
# TWO INITIATORS (a single host couldn't saturate the target):
#   stream5  -> the 4 subsystems on 10.3.96.10  (its ens3np0/.96 NIC)
#   stream6  -> the 4 subsystems on 10.3.95.10  (its ens2np0/.95 NIC)
# Both send concurrently; the per-point throughput is the SUM of the two
# initiators' steady TX (writes flow initiator -> rapids0, so initiator TX == the
# target receive rate). stream5 orchestrates and drives stream6 over SSH.
#
# Role: both initiators are SENDERS -> nvme_pdu_align is set on BOTH. rapids0 is
# the RECEIVER and is the core-swept side.
#
# Configs (CONFIGS):
#   linux    : pdu 0 ; rapids0 kernel nvmet + zcopy OFF
#   spdk     : pdu 0 ; rapids0 SPDK target (/opt/spdk_target.sh <cores>)
#   zcIO-MT  : pdu 2 ; rapids0 kernel nvmet + zcopy ON  ; fio threads (thread=1)
#   zcIO-MP  : pdu 2 ; rapids0 kernel nvmet + zcopy ON  ; fio processes
#
# Required kernels (boot manually first; ./kernel-switch.sh write):
#   stream5 + stream6 : 5.15.189-pduwin      rapids0 : 6.11.0-target-zc-add-frozen+
#
# Results: results-<config>/summary.csv.  Plot:  python3 plot.py
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
rm -rf results-* 2>/dev/null || true   # fresh results each run

RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
export RAPIDS0
export RAPIDS0_DIR="${RAPIDS0_DIR:-/home/$(whoami)/zcio-ae-7b}"
STREAM6="${STREAM6:-stream6.snu.ac.kr}"
export STREAM6
export STREAM6_DIR="${STREAM6_DIR:-/home/$(whoami)/zcio-ae-7b-init}"
SSHOPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5"
SSH="ssh $SSHOPTS $RAPIDS0"
SSH6="ssh $SSHOPTS $STREAM6"

# initiator data-NIC IPs (this host = .96, stream6 = .95)
S5_IP="10.3.96.5"
S6_IP="10.3.95.2"

CONFIGS=(${CONFIGS:-linux zcIO-MT zcIO-MP spdk})   # spdk LAST: its residual degrades the next config's first point
CORE_SWEEP="${CORE_SWEEP:-15 12 8 4 2 1}"     # rapids0 cores, MUST be descending

# ----- preflight ------------------------------------------------------
echo ">>> preflight: NOPASSWD sudo + SSH (verify kernels first with: ./kernel-switch.sh write) ..."
sudo -n -l "$(pwd)/measure-host.sh" >/dev/null 2>&1 || { echo "!! stream5 NOPASSWD missing — run ../deploy.sh"; exit 1; }
$SSH  true 2>/dev/null || { echo "!! cannot ssh $RAPIDS0 (passwordless) — run ../deploy.sh"; exit 1; }
$SSH6 true 2>/dev/null || { echo "!! cannot ssh $STREAM6 (passwordless) — run ../deploy.sh / ssh-copy-id $STREAM6"; exit 1; }
$SSH6 sudo -n true 2>/dev/null || { echo "!! $STREAM6 NOPASSWD sudo missing — run ../deploy.sh"; exit 1; }
echo "  cores: $CORE_SWEEP   initiators: stream5(.96) + stream6(.95)"

# ----- staging --------------------------------------------------------
# Take ownership of the dst dir once, then copy with plain user perms.
stage_to() {  # host srcdir dstdir
    local host="$1" srcdir="$2" dstdir="$3"
    [ -d "$srcdir" ] || { echo "!! stage: $srcdir missing"; return 1; }
    ssh $SSHOPTS "$host" "sudo mkdir -p $dstdir && sudo chown -R \$(id -un):\$(id -gn) $dstdir" \
        || { echo "!! [$host] could not take ownership of $dstdir"; return 1; }
    tar czf - -C "$srcdir" . \
        | ssh $SSHOPTS "$host" "tar xzf - -C $dstdir && chmod +x $dstdir/*.sh 2>/dev/null; true"
}
stage_files_to() {  # host dstdir file...
    local host="$1" dstdir="$2"; shift 2
    ssh $SSHOPTS "$host" "sudo mkdir -p $dstdir && sudo chown -R \$(id -un):\$(id -gn) $dstdir" \
        || { echo "!! [$host] could not take ownership of $dstdir"; return 1; }
    tar czf - "$@" | ssh $SSHOPTS "$host" "tar xzf - -C $dstdir && chmod +x $dstdir/*.sh 2>/dev/null; true"
}
echo ">>> staging target scripts to $RAPIDS0:$RAPIDS0_DIR"
stage_to "$RAPIDS0" "$(pwd)/rapids0" "$RAPIDS0_DIR" || { echo "!! staging failed"; exit 1; }
echo ">>> staging initiator scripts to $STREAM6:$STREAM6_DIR"
stage_files_to "$STREAM6" "$STREAM6_DIR" \
    buffer.sh stream6-net.sh stream6-restore.sh set-pdu-align.sh cpu-governor.sh \
    connect-targets.sh disconnect-targets.sh measure-host.sh workload-*.fio \
    || { echo "!! stream6 staging failed"; exit 1; }
$SSH6 "rm -rf $STREAM6_DIR/results-* 2>/dev/null; true"

# ----- fresh-SLC clean start: nvme-format the 9100 PROs, settle, and VERIFY clean
# BEFORE the run (SKIP_FORMAT=1 to skip; FMT_IDLE_SECS to tune the settle wait).
echo; echo ">>> [rapids0] format-9100.sh — fresh-SLC clean start (format + settle + verify)"
$SSH sudo -n "$RAPIDS0_DIR/format-9100.sh" || { echo "!! format-9100 failed — aborting (devices not clean)"; exit 1; }

# ----- initiator data-plane (both senders, full cores, once) ----------
online_all_cores_local() {
    local off; off="$(cat /sys/devices/system/cpu/offline 2>/dev/null)"
    [ -z "$off" ] && return 0
    echo ">>> [stream5] onlining offline cores ($off) — sender needs full cores"
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        id="${c##*/cpu}"; [ "$id" = 0 ] && continue
        [ -e "$c/online" ] && echo 1 | sudo tee "$c/online" >/dev/null
    done
}
online_all_cores_local
$SSH6 'sudo -n bash -c "for c in /sys/devices/system/cpu/cpu[0-9]*; do id=\${c##*/cpu}; [ \"\$id\" = 0 ] && continue; [ -e \"\$c/online\" ] && echo 1 > \"\$c/online\"; done"' || true
echo ">>> [stream5] online cores: $(nproc)  |  [stream6] online cores: $($SSH6 nproc 2>/dev/null)"

echo; echo ">>> [stream5] data plane: buffers + net (reload mlx5 + MTU 9000)"
./buffer.sh                   || echo "!! stream5 buffer.sh failed (continuing)"
./stream5-net.sh              || { echo "!! stream5 net setup failed"; exit 1; }
# both initiators are full-core SENDERS — pin them to performance so the sender CPU
# never throttles (a throttled stream5 sends slower -> NIC-RX imbalance at the target).
sudo -n ./cpu-governor.sh performance >/dev/null 2>&1 || echo "!! stream5 cpu-governor failed (continuing)"
echo ">>> [stream6] data plane: buffers + net"
$SSH6 sudo -n "$STREAM6_DIR/buffer.sh"      || echo "!! stream6 buffer.sh failed (continuing)"
$SSH6 sudo -n "$STREAM6_DIR/stream6-net.sh" || { echo "!! stream6 net setup failed"; exit 1; }
$SSH6 sudo -n "$STREAM6_DIR/cpu-governor.sh" performance >/dev/null 2>&1 || echo "!! stream6 cpu-governor failed (continuing)"

# ----- helpers that act on BOTH initiators ----------------------------
pdu_both() {  # 0|2
    ./set-pdu-align.sh "$1"                              || echo "  !! stream5 set-pdu-align $1 failed"
    $SSH6 sudo -n "$STREAM6_DIR/set-pdu-align.sh" "$1"   || echo "  !! stream6 set-pdu-align $1 failed"
}
connect_both() {  # kernel|spdk
    local mode="$1" p6
    $SSH6 sudo -n "$STREAM6_DIR/connect-targets.sh" "$mode" 95 & p6=$!
    ./connect-targets.sh "$mode" 96 ; local rc5=$?
    wait "$p6"; local rc6=$?
    [[ "$rc5" -eq 0 && "$rc6" -eq 0 ]]
}
disconnect_both() {
    ./disconnect-targets.sh || true
    $SSH6 sudo -n "$STREAM6_DIR/disconnect-targets.sh" || true
}

# Run ONE point: fio concurrently on both initiators, then SUM the steady TX.
measure_2host() {  # config n fiofile
    local config="$1" n="$2" fio="$3"
    local out="results-$config"
    mkdir -p "$out"
    local sum="$out/summary.csv"
    [[ -f "$sum" ]] || echo "cores,net_steady_GBps,steady_CoV_pct,fio_write_MiBps,fio_write_kIOPS,fio_clat_us_mean" > "$sum"

    echo "[measure-2host] $config cores=$n : fio on stream5(.96) + stream6(.95)"
    local p5 p6
    $SSH6 sudo -n "$STREAM6_DIR/measure-host.sh" "$out" "$n" "$fio" "$S6_IP" & p6=$!
    sudo -n ./measure-host.sh "$out" "$n" "$fio" "$S5_IP"               & p5=$!
    wait "$p5" || echo "  !! stream5 measure-host exited nonzero"
    wait "$p6" || echo "  !! stream6 measure-host exited nonzero"

    local g5=0 c5=0 m5=0 i5=0 l5=0 g6=0 c6=0 m6=0 i6=0 l6=0
    if [[ -f "$out/$n.result" ]]; then read -r g5 c5 m5 i5 l5 < "$out/$n.result"; else echo "  !! stream5 result missing"; fi
    local r6; r6="$($SSH6 cat "$STREAM6_DIR/$out/$n.result" 2>/dev/null)"
    if [[ -n "$r6" ]]; then read -r g6 c6 m6 i6 l6 <<< "$r6"; else echo "  !! stream6 result missing"; fi

    local row
    row=$(awk -v g5="$g5" -v g6="$g6" -v c5="$c5" -v c6="$c6" -v m5="$m5" -v m6="$m6" \
              -v i5="$i5" -v i6="$i6" -v l5="$l5" -v l6="$l6" -v n="$n" 'BEGIN{
        gt=g5+g6; mt=m5+m6; it=i5+i6; cov=(c5>c6)?c5:c6;
        lt=0; nl=0; if(l5>0){lt+=l5;nl++}; if(l6>0){lt+=l6;nl++}; lm=(nl>0)?lt/nl:0;
        printf "%s,%.2f,%.2f,%.1f,%.1f,%.1f", n, gt, cov, mt, it, lm }')
    echo "$row" >> "$sum"
    echo "  [total] cores=$n : $(cut -d, -f2 <<<"$row") GB/s  (s5=$g5 + s6=$g6)  | $(cut -d, -f4 <<<"$row") MiB/s, $(cut -d, -f5 <<<"$row") kIOPS, clat $(cut -d, -f6 <<<"$row") us"
}

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
    # path is limited too, AND the SPDK core mask (cpu0..N-1) matches the online
    # cores so DPDK EAL is happy. cpu-limit flaps mlx5, so wait for the NICs back.
    $SSH sudo -n "$RAPIDS0_DIR/cpu-limit.sh" "$cores"  || echo "!! cpu-limit failed"
    # IRQ_SPLIT=1: pin the two target NICs to DISJOINT cores (set-irq-affinity.sh,
    # stops irqbalance) so two-host write RX doesn't contend on shared cores (the
    # "one NIC hot, one cold" imbalance). Unset -> leave irqbalance on.
    [[ -n "${IRQ_SPLIT:-}" ]] && $SSH sudo -n "$RAPIDS0_DIR/set-irq-affinity.sh" || true
    $SSH sudo -n "$RAPIDS0_DIR/cpu-governor.sh" performance || true
    wait_nics_settle
    $SSH sudo -n "$RAPIDS0_DIR/spdk-target-start.sh" "$cores" || { echo "!! spdk target start failed"; return 1; }
}

run_kernel_config() {  # config zcopy pdu
    local config="$1" zc="$2" pdu="$3" n
    setup_kernel_target_full "$zc" || return 1
    pdu_both "$pdu"
    connect_both kernel || { echo "!! connect failed — skipping $config"; disconnect_both; return 1; }
    for n in $CORE_SWEEP; do
        echo "---------------- $config: rapids0 cores=$n ----------------"
        $SSH sudo -n "$RAPIDS0_DIR/cpu-limit.sh" "$n"       || echo "  !! cpu-limit $n failed"
        # IRQ_SPLIT=1: pin two NICs to disjoint cores (see setup_spdk_target note).
        [[ -n "${IRQ_SPLIT:-}" ]] && $SSH sudo -n "$RAPIDS0_DIR/set-irq-affinity.sh" || true
        sleep 1
        measure_2host "$config" "$n" "workload-$config-$n.fio" \
            || echo "  !! measure $config cores=$n failed"
    done
    [[ -n "${KEEP_UP:-}" ]] || disconnect_both
}

run_spdk_config() {  # restart target + reconnect at each core count
    local n
    pdu_both 0
    for n in $CORE_SWEEP; do
        echo "---------------- spdk: rapids0 cores=$n ----------------"
        setup_spdk_target "$n" || { echo "  !! spdk setup $n failed"; continue; }
        connect_both spdk || { echo "  !! connect failed cores=$n"; disconnect_both; continue; }
        measure_2host spdk "$n" "workload-spdk-$n.fio" \
            || echo "  !! measure spdk cores=$n failed"
        if [[ -n "${KEEP_UP:-}" ]]; then
            echo ">>> KEEP_UP set — leaving SPDK target + nvme connections up (cores=$n); not sweeping further"
            break
        fi
        disconnect_both
    done
    [[ -n "${KEEP_UP:-}" ]] || $SSH sudo -n "$RAPIDS0_DIR/spdk-target-stop.sh" || true
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
echo "# COMBINED: steady net TX (GB/s, stream5+stream6) by rapids0 core count"
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
if [[ -n "${KEEP_UP:-}" ]]; then
    echo; echo ">>> KEEP_UP set — skipping restore. Target/SPDK + nvme connections left up for manual fio."
    echo "    stream5 connected NVMe-oF devices (.96 group):"
    for b in /sys/block/nvme*n*; do
        bn="$(basename "$b")"; [[ "$bn" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        [[ "$(cat "$b/device/transport" 2>/dev/null)" == tcp ]] && echo "      /dev/$bn"
    done
    echo "    stream6 connected devices (.95 group):"
    $SSH6 'for b in /sys/block/nvme*n*; do bn=$(basename "$b"); [[ "$bn" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue; [[ "$(cat "$b/device/transport" 2>/dev/null)" == tcp ]] && echo "      [stream6] /dev/$bn"; done' 2>/dev/null || true
    echo "    when done, tear down with:"
    echo "      ./disconnect-targets.sh ; $SSH6 sudo -n $STREAM6_DIR/disconnect-targets.sh"
    echo "      $SSH sudo -n $RAPIDS0_DIR/spdk-target-stop.sh"
    echo "      ./stream5-restore.sh ; $SSH6 sudo -n $STREAM6_DIR/stream6-restore.sh ; $SSH sudo -n $RAPIDS0_DIR/target-restore.sh"
else
    echo; echo ">>> restore: stream5+stream6 net + pdu_align 0 ; rapids0 cores online + kernel nvmet baseline"
    pdu_both 0 || true
    ./stream5-restore.sh || echo "!! stream5 restore reported an error"
    $SSH6 sudo -n "$STREAM6_DIR/stream6-restore.sh" || echo "!! stream6 restore reported an error"
    $SSH sudo -n "$RAPIDS0_DIR/spdk-target-stop.sh"   || true
    $SSH sudo -n "$RAPIDS0_DIR/restore-tcp-config.sh" || true
    $SSH sudo -n "$RAPIDS0_DIR/target-restore.sh"     || echo "!! rapids0 target-restore reported an error"
fi
echo "[all-in-one fig-7b] done."
