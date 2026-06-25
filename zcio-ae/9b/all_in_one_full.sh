#!/bin/bash
# all_in_one_full.sh — figure 9b (MLPerf Storage): full UNet3D CPU-core sweep, default vs zcIO.
# (For the quick 3-point default run — default@{6,10}, zcIO@{6} — use ./all_in_one.sh.)
#
# Per config it connects NVMe/TCP at FULL cores, mounts the 4 drives, then runs the
# UNet3D online-core sweep (sweep-unet3d.sh: OFFLINE cpus to N online cores — NOT
# taskset — run mlpstorage, parse the [METRIC] AU%). Metric = AU% (Accelerator
# Utilization) per online-core count: "min cores to keep the 8 GPUs fed".
#
#   default : ZCOPY=off + nvme_pdu_align=0   (stock Linux baseline)
#   zcIO    : ZCOPY=on  + nvme_pdu_align=2
#
# Per config:
#   [bring up]  set-cores all -> ./{default_setup,zc_setup}.sh  (connect at full cores)
#   [mount]     ./mount_4disk.sh   (mkfs + mount the 4 drives)
#   [sweep]     ./sweep-unet3d.sh <config> <outdir>
#                 -> setup_permissions.sh + setup_4disk.sh (datagen)
#                 -> per core N: offline to N, run mlpstorage, parse AU
#   [report]    combined AU-per-core table + plot.py
#
# Prereqs (one-time, NOT per figure):
#   ../deploy.sh            -> global NOPASSWD sudo + passwordless SSH (all hosts)
#   /opt/mlperf-env is pre-provisioned & shared on this machine (venv + modified mlpstorage + dlio)
# This figure stages its OWN rapids0/ scripts each run; no per-figure deploy.
#
#   Usage:   ./all_in_one_full.sh
#   Subset:  CONFIGS="default" CORES="2 4 8" ./all_in_one_full.sh
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
HERE="$(pwd)"

# knobs (CONFIGS / GPUs / threads / cores) live in config.sh — EDIT THERE.
# shellcheck disable=SC1091
[ -f "$HERE/config.sh" ] && source "$HERE/config.sh"

ENV_DIR="${ENV_DIR:-$HERE}"                              # NVMe/TCP env scripts (self-contained in fig-9b)
CONFIGS=(${CONFIGS:-default zcIO})
MOUNT_SH="${MOUNT_SH:-./mount_4disk.sh}"
UNMOUNT_SH="${UNMOUNT_SH:-./unmount_4disk.sh}"
SWEEP_SH="${SWEEP_SH:-$HERE/sweep-unet3d.sh}"
PLOT_PY="${PLOT_PY:-$HERE/plot.py}"
OUTDIR="${OUTDIR:-results}"; mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
SETTLE="${SETTLE:-3}"                                    # seconds to let NVMe/TCP + mounts settle between ops

# settle pause between mount/unmount/connect/disconnect so the kernel finishes
# tearing down / bringing up state before the next op (avoids stale ctrl races).
settle() { sleep "$SETTLE"; }

# rapids0 target: staged fresh each run (no per-figure deploy; repo-root
# ../deploy.sh installs global NOPASSWD + passwordless SSH).
RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
export RAPIDS0
export RAPIDS0_DIR="${RAPIDS0_DIR:-/home/$(whoami)/zcio-ae-9b}"
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
# (3) read-path kernels on BOTH hosts (stream5=6.11.0-hostzc+, rapids0=5.15.189-pduwin)
echo ">>> preflight: verifying read-path kernels (./kernel-switch.sh read) ..."
./kernel-switch.sh read || {
    echo "!! wrong kernel(s) — fig-9 needs the READ path."
    echo "   stream5: sudo ./reboot-to-kernel.sh 6.11      (-> 6.11.0-hostzc+)"
    echo "   rapids0: boot 5.15.189-pduwin   (or: ./kernel-switch.sh read --reboot)"
    exit 1; }
# (4) env + sweep scripts present
for s in default_setup.sh zc_setup.sh disconnect.sh set-cores.sh; do
    [[ -x "$ENV_DIR/$s" ]] || { echo "!! missing env script $ENV_DIR/$s"; exit 1; }
done
[[ -x "$SWEEP_SH" ]] || { echo "!! missing sweep worker: $SWEEP_SH"; exit 1; }

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

# stream5 (receiver) governor -> performance (powersave caps single-core read)
echo ">>> [initiator stream5] CPU governor -> performance"
sudo -n ./cpu-governor.sh performance >/dev/null 2>&1 || echo "!! cpu-governor performance failed (continuing)"

# bring a config up = connect NVMe/TCP with the right zcopy/pdu knobs
bring_up() {
    case "$1" in
        default) "$ENV_DIR/default_setup.sh" ;;   # zcopy off + pdu 0
        zcIO)    "$ENV_DIR/zc_setup.sh" ;;         # zcopy on  + pdu 2
        *) echo "unknown config '$1'"; return 1 ;;
    esac
}

# unmount the 4 data filesystems robustly (lazy-umount any straggler so
# /mnt/rocksdb_test/testdb* never lingers and blocks the next config).
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

# ----- per-config core sweep ------------------------------------------
for cfg in "${CONFIGS[@]}"; do
    echo
    echo "############################################################"
    echo "# config: $cfg   (UNet3D online-core sweep)"
    echo "############################################################"
    "$ENV_DIR/disconnect.sh" || echo "!! disconnect reported an error (continuing)"
    settle

    echo ">>> [$cfg] all cores ON (connect at full cores)"
    "$ENV_DIR/set-cores.sh" all

    echo ">>> [$cfg] bringing up NVMe/TCP stack ..."
    if ! bring_up "$cfg"; then
        echo "!! setup failed for $cfg — skipping"; "$ENV_DIR/set-cores.sh" all; settle; continue
    fi
    settle

    echo ">>> [$cfg] mount"
    "$MOUNT_SH"
    settle

    echo ">>> [$cfg] UNet3D online-core sweep ..."
    # low-AU cores (1,2) barely change across epochs -> run just 1 epoch there to save time
    ENV_DIR="$ENV_DIR" LOW_EPOCH_CORES="${LOW_EPOCH_CORES:-1 2}" "$SWEEP_SH" "$cfg" "$OUTDIR" \
        || echo "!! sweep error for $cfg (continuing)"

    cd "$HERE"
    echo
    echo ">>> [$cfg] done — restore cores + unmount + disconnect"
    "$ENV_DIR/set-cores.sh" all
    safe_unmount
    settle
    "$ENV_DIR/disconnect.sh" || echo "!! disconnect reported an error (continuing)"
    settle
done

# ----- final cleanup --------------------------------------------------
echo
echo ">>> cleanup: restore cores + unmount + disconnect ..."
"$ENV_DIR/set-cores.sh" all
safe_unmount
settle
"$ENV_DIR/disconnect.sh" || echo "!! disconnect reported an error"

# ----- combined report + plot -----------------------------------------
echo
echo "############################################################"
echo "# COMBINED: UNet3D AU% per online-core count (default vs zcIO)"
echo "############################################################"
python3 "$PLOT_PY" "$OUTDIR" "${CONFIGS[@]}" || echo "!! plot.py failed"

echo
echo "[all-in-one] done. Per-config CSVs + plot under: $OUTDIR/"
