#!/bin/bash
# all_in_one.sh — figure 9b (default run): 3-point comparison, only 3 (config, cores) points.
#
#       default @ 6 cores  ·  default @ 10 cores  ·  zcIO @ 6 cores
#
# This is the default 9b run — enough to show zcIO reaches the AU>=90% target at
# fewer cores. For the full per-config core sweep (1,2,4,6,8,10) use
# all_in_one_full.sh instead.
#
# Same flow as all_in_one_full.sh but with a PER-CONFIG core list. Each config
# still datagens once (a config change reconnects + re-mkfs's the disks, wiping
# data), so this runs 2 datagens total — default (cores 6,10) and zcIO (core 6).
#
# Prereqs (one-time): ../deploy.sh   (/opt/mlperf-env is pre-provisioned & shared on this machine)
#   Usage:  ./all_in_one.sh
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
HERE="$(pwd)"

ENV_DIR="${ENV_DIR:-$HERE}"
CONFIGS=(default zcIO)
# per-config online-core list (THIS is the only real difference from all_in_one_full.sh)
cores_for() { case "$1" in default) echo "6 10" ;; zcIO) echo "6" ;; *) echo "" ;; esac; }
MOUNT_SH="${MOUNT_SH:-./mount_4disk.sh}"
UNMOUNT_SH="${UNMOUNT_SH:-./unmount_4disk.sh}"
SWEEP_SH="${SWEEP_SH:-$HERE/sweep-unet3d.sh}"
PLOT_PY="${PLOT_PY:-$HERE/plot.py}"
OUTDIR="${OUTDIR:-results}"; mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
SETTLE="${SETTLE:-3}"
settle() { sleep "$SETTLE"; }

RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
export RAPIDS0
export RAPIDS0_DIR="${RAPIDS0_DIR:-/home/$(whoami)/zcio-ae-9b}"
SSHOPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5"

# ----- preflight ------------------------------------------------------
echo ">>> preflight ..."
[[ -f /opt/mlperf-env/venv/bin/activate ]] \
    || { echo "!! /opt/mlperf-env not found — it is pre-provisioned & shared on this machine; contact the maintainer"; exit 1; }
[[ -x /opt/mlperf-env/venv/bin/mlpstorage ]] \
    || { echo "!! /opt/mlperf-env/mlperf_storage missing — pre-provisioned & shared on this machine; contact the maintainer"; exit 1; }
sudo -n true 2>/dev/null \
    || { echo "!! NOPASSWD sudo missing — run the repo-root ./deploy.sh first"; exit 1; }
ssh $SSHOPTS "$RAPIDS0" true 2>/dev/null \
    || { echo "!! cannot ssh $RAPIDS0 (passwordless) — run the repo-root ./deploy.sh first"; exit 1; }
echo ">>> preflight: verifying read-path kernels (./kernel-switch.sh read) ..."
./kernel-switch.sh read || {
    echo "!! wrong kernel(s) — fig-9 needs the READ path."
    echo "   stream5: sudo ./reboot-to-kernel.sh 6.11      (-> 6.11.0-hostzc+)"
    echo "   rapids0: boot 5.15.189-pduwin   (or: ./kernel-switch.sh read --reboot)"
    exit 1; }
for s in default_setup.sh zc_setup.sh disconnect.sh set-cores.sh; do
    [[ -x "$ENV_DIR/$s" ]] || { echo "!! missing env script $ENV_DIR/$s"; exit 1; }
done
[[ -x "$SWEEP_SH" ]] || { echo "!! missing sweep worker: $SWEEP_SH"; exit 1; }

# ----- stage rapids0 target scripts -----------------------------------
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

echo ">>> [initiator stream5] CPU governor -> performance"
sudo -n ./cpu-governor.sh performance >/dev/null 2>&1 || echo "!! cpu-governor performance failed (continuing)"

bring_up() {
    case "$1" in
        default) "$ENV_DIR/default_setup.sh" ;;
        zcIO)    "$ENV_DIR/zc_setup.sh" ;;
        *) echo "unknown config '$1'"; return 1 ;;
    esac
}
safe_unmount() {
    "$UNMOUNT_SH" 2>&1 | sed 's/^/  /' || echo "  (unmount reported an error)"
    local m left=0
    for m in /mnt/rocksdb_test/testdb*; do
        [[ -d "$m" ]] || continue
        mountpoint -q "$m" 2>/dev/null && { echo "  !! $m STILL mounted -> lazy umount"; sudo umount -l "$m" 2>/dev/null || left=1; }
    done
    [[ $left == 0 ]] && echo "  [unmount] released" || echo "  [unmount] some remain"
}

# ----- per-config (with per-config core list) -------------------------
for cfg in "${CONFIGS[@]}"; do
    CORES_LIST="$(cores_for "$cfg")"
    echo
    echo "############################################################"
    echo "# config: $cfg   (FAST: cores = $CORES_LIST)"
    echo "############################################################"
    "$ENV_DIR/disconnect.sh" || echo "!! disconnect error (continuing)"
    settle
    echo ">>> [$cfg] all cores ON (connect at full cores)"
    "$ENV_DIR/set-cores.sh" all
    echo ">>> [$cfg] bringing up NVMe/TCP stack ..."
    if ! bring_up "$cfg"; then echo "!! setup failed for $cfg — skipping"; "$ENV_DIR/set-cores.sh" all; settle; continue; fi
    settle
    echo ">>> [$cfg] mount"
    "$MOUNT_SH"
    settle
    echo ">>> [$cfg] UNet3D sweep (cores: $CORES_LIST) ..."
    ENV_DIR="$ENV_DIR" CORES="$CORES_LIST" "$SWEEP_SH" "$cfg" "$OUTDIR" || echo "!! sweep error for $cfg (continuing)"
    cd "$HERE"
    echo
    echo ">>> [$cfg] done — restore cores + unmount + disconnect"
    "$ENV_DIR/set-cores.sh" all
    safe_unmount
    settle
    "$ENV_DIR/disconnect.sh" || echo "!! disconnect error (continuing)"
    settle
done

echo
echo ">>> cleanup: restore cores + unmount + disconnect ..."
"$ENV_DIR/set-cores.sh" all
safe_unmount
settle
"$ENV_DIR/disconnect.sh" || echo "!! disconnect error"

# ----- combined report + plot -----------------------------------------
echo
echo "############################################################"
echo "# FAST: UNet3D AU% — default@{6,10} vs zcIO@{6}"
echo "############################################################"
python3 "$PLOT_PY" "$OUTDIR" "${CONFIGS[@]}" || echo "!! plot.py failed"
echo
echo "[all_in_one] done. CSVs + plot under: $OUTDIR/"
