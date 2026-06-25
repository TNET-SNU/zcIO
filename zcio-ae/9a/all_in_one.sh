#!/bin/bash
# all_in_one.sh — figure 9a (MLPerf Storage): default-vs-zcIO across 3 workloads.
#       unet3d  ·  llama3 (load)  ·  cosmoflow   (single-core peak ens2np0 Gbps)
#
#   default : ZCOPY=off + nvme_pdu_align=0   (stock Linux baseline)
#   zcIO    : ZCOPY=on  + nvme_pdu_align=2
#
# Per config:
#   [bring up]  ./{default_setup,zc_setup}.sh           (connect NVMe/TCP, set knobs)
#   [workload]  ./workload-<w>.sh <config> <outdir>     (one per MLPerf workload)
#   [report]    combined default-vs-zcIO table + plot.py
#
# Prereqs (one-time, NOT per figure):
#   ../deploy.sh            -> global NOPASSWD sudo + passwordless SSH (all hosts)
#   /opt/mlperf-env is pre-provisioned & shared on this machine (venv + modified mlpstorage + dlio)
# This figure stages its OWN rapids0/ scripts each run, so there is no per-figure
# deploy step.
#
#   Usage:   ./all_in_one.sh
#   Subset:  CONFIGS="default" WORKLOADS="unet3d" ./all_in_one.sh
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

ENV_DIR="${ENV_DIR:-.}"                          # NVMe/TCP env scripts (local, this figure)
CONFIGS=(${CONFIGS:-default zcIO})
WORKLOADS=(${WORKLOADS:-unet3d llama3 cosmoflow})
OUTDIR="${OUTDIR:-results}"
UNMOUNT_SH="${UNMOUNT_SH:-./unmount_4disk.sh}"

# rapids0 target: staged fresh each run (no per-figure deploy; repo-root
# ../deploy.sh installs global NOPASSWD + passwordless SSH).
RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
export RAPIDS0
export RAPIDS0_DIR="${RAPIDS0_DIR:-/home/$(whoami)/zcio-ae-9a}"
SSHOPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5"

# ----- preflight ------------------------------------------------------
echo ">>> preflight ..."
# (1) shared MLPerf env provisioned in /opt ?
[[ -f /opt/mlperf-env/venv/bin/activate ]] \
    || { echo "!! /opt/mlperf-env not found — it is pre-provisioned & shared on this machine; contact the maintainer"; exit 1; }
[[ -x /opt/mlperf-env/venv/bin/mlpstorage ]] \
    || { echo "!! /opt/mlperf-env/mlperf_storage missing — pre-provisioned & shared on this machine; contact the maintainer"; exit 1; }
# (2) global NOPASSWD sudo + passwordless ssh (from ../deploy.sh)
sudo -n true 2>/dev/null \
    || { echo "!! NOPASSWD sudo missing — run the repo-root ./deploy.sh first"; exit 1; }
ssh $SSHOPTS "$RAPIDS0" true 2>/dev/null \
    || { echo "!! cannot ssh $RAPIDS0 (passwordless) — run the repo-root ./deploy.sh first"; exit 1; }
# (3) correct read-path kernels on BOTH hosts (stream5=6.11.0-hostzc+, rapids0=5.15.189-pduwin)
echo ">>> preflight: verifying read-path kernels (./kernel-switch.sh read) ..."
./kernel-switch.sh read || {
    echo "!! wrong kernel(s) — fig-9 needs the READ path."
    echo "   stream5: sudo ./reboot-to-kernel.sh 6.11      (-> 6.11.0-hostzc+)"
    echo "   rapids0: boot 5.15.189-pduwin   (or: ./kernel-switch.sh read --reboot)"
    exit 1; }
# (4) env + workload scripts present
for s in default_setup.sh zc_setup.sh disconnect.sh; do
    [[ -x "$ENV_DIR/$s" ]] || { echo "!! missing env script $ENV_DIR/$s"; exit 1; }
done
for wl in "${WORKLOADS[@]}"; do
    [[ -x "./workload-${wl}.sh" ]] || { echo "!! missing ./workload-${wl}.sh"; exit 1; }
done
mkdir -p "$OUTDIR"

# ----- stage rapids0 target scripts (self-contained, each run) --------
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

# ----- stream5 (receiver) CPU governor -> performance ------------------
# fig-9 measures single-core read on the initiator (stream5); powersave caps the
# core and depresses throughput, so pin performance here. (rapids0 governor is
# set by setup.sh.)
echo ">>> [initiator stream5] CPU governor -> performance"
sudo -n ./cpu-governor.sh performance >/dev/null 2>&1 || echo "!! cpu-governor performance failed (continuing)"

# bring a config up = connect NVMe/TCP with the right zcopy/pdu knobs (shared env)
bring_up() {
    case "$1" in
        default) "$ENV_DIR/default_setup.sh" ;;   # zcopy off + pdu 0
        zcIO)    "$ENV_DIR/zc_setup.sh" ;;         # zcopy on  + pdu 2
        *) echo "unknown config '$1'"; return 1 ;;
    esac
}

# unmount the 4 data filesystems, robustly. unmount_4disk.sh can leave them
# mounted if a workload process is still holding them ("busy"); verify and
# lazy-umount any straggler so /mnt/rocksdb_test/testdb* never lingers.
safe_unmount() {
    "$UNMOUNT_SH" 2>&1 | sed 's/^/  /' || echo "  (unmount_4disk.sh reported an error)"
    local m left=0
    for m in /mnt/rocksdb_test/testdb*; do
        [[ -d "$m" ]] || continue
        if mountpoint -q "$m" 2>/dev/null; then
            echo "  !! $m STILL mounted (busy) -> lazy umount"
            sudo umount -l "$m" 2>/dev/null || { left=1; echo "  !! could not release $m"; }
        fi
    done
    if [[ $left == 0 ]]; then echo "  [unmount] all /mnt/rocksdb_test/testdb* released";
    else echo "  [unmount] some mounts remain — check: fuser -m /mnt/rocksdb_test/testdb*"; fi
}

# ----- per-workload x per-config sweep --------------------------------
# Outer loop = WORKLOAD. For each workload we run all configs (default, then zcIO)
# back-to-back, generating the disk data only ONCE -- for the FIRST config -- and
# REUSING it for the rest (the data is identical across configs; only the kernel
# knobs differ). A new workload's first config reformats the disks (fresh data).
#
#   workload A: default (mkfs + datagen) -> zcIO (REUSE, no reinit)
#   workload B: default (mkfs + datagen) -> zcIO (REUSE, no reinit)
#   ...
for wl in "${WORKLOADS[@]}"; do
    echo
    echo "############################################################"
    echo "# workload: $wl"
    echo "############################################################"
    ci=0
    for cfg in "${CONFIGS[@]}"; do
        # first config of this workload -> fresh disk (REUSE=0: mkfs + datagen);
        # later configs -> reuse the same data (REUSE=1: no mkfs, datagen auto-skips).
        if [[ $ci -eq 0 ]]; then reuse=0; else reuse=1; fi
        [[ $reuse -eq 1 ]] && tag="REUSE data" || tag="fresh disk"

        echo
        echo ">>> [$wl/$cfg] disconnect + bring up NVMe/TCP ($tag) ..."
        "$ENV_DIR/disconnect.sh" || echo "!! disconnect reported an error (continuing)"
        if ! bring_up "$cfg"; then
            echo "!! setup failed for $cfg — skipping"; ci=$((ci + 1)); continue
        fi

        echo ">>> [$wl/$cfg] workload run (REUSE=$reuse)"
        if ! REUSE="$reuse" "./workload-${wl}.sh" "$cfg" "$OUTDIR"; then
            echo "!! workload $wl failed for $cfg (continuing)"
        fi
        echo ">>> [$wl/$cfg] done — unmount"
        safe_unmount
        ci=$((ci + 1))
    done

    # workload done: drop the NVMe/TCP sessions before the next workload
    echo
    echo ">>> [$wl] all configs done — disconnect"
    "$ENV_DIR/disconnect.sh" || echo "!! disconnect reported an error (continuing)"
done

# ----- final cleanup --------------------------------------------------
echo
echo ">>> cleanup: unmount + disconnect NVMe/TCP ..."
safe_unmount
"$ENV_DIR/disconnect.sh" || echo "!! disconnect reported an error"

# ----- combined report (TODO) -----------------------------------------
echo
echo "############################################################"
echo "# COMBINED: MLPerf Storage default vs zcIO (per workload)"
echo "############################################################"
python3 ./plot.py "$OUTDIR" "${CONFIGS[@]}" || echo "!! plot.py failed"

echo
echo "[mlperf-all-in-one] done. Per-workload results under: $OUTDIR/"
