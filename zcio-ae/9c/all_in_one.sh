#!/bin/bash
# all-in-one.sh — fig-9a RocksDB single-core read-IOPS: full default-vs-zcIO sweep.
#
# For each config it brings the WHOLE stack to that config, rebuilds the 4-disk
# DB, and runs the single-core readrand IOPS sweep (5 block sizes x REPS reps):
#
#   default (Linux):  ZCOPY=off + nvme_pdu_align=0      (both zero-copy knobs OFF)
#   zcIO          :  ZCOPY=on  + nvme_pdu_align=2      (both ON — must be paired)
#
# Per config:
#   [bring up]  NET_PDU/ZCOPY ./setup.sh   (target nvmet up, full cores, connect)
#   [disks]     unmount -> mount_4disk.sh  (mkfs + mount the 4 NVMe/TCP devices)
#   [measure]   rocksdb-run.sh <cfg> ... none   (PIN=none: does NOT touch CPU on/off;
#                                          core state is managed externally by you)
#   -> results-rocksdb-<cfg>.csv  (copied into this dir)
#
# Then a combined table + plot.py (default vs zcIO grouped bars).
#
# Requires: fig-9a ./deploy.sh done (NOPASSWD on both hosts) and the RocksDB
# harness in ROCKSDB_DIR (make_4disks.sh, read_4disks.sh, mount_4disk.sh,
# rocksdb-run.sh, custom_rocksdb). Read-path kernels per ../README (stream5
# 6.11.0-hostzc+, rapids0 5.15.189-pduwin) — switch separately, not here.
#
#   Usage:  ./all-in-one.sh
#   Subset: CONFIGS="default" ./all-in-one.sh
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
HERE="$(pwd)"

# rapids0 target: staged fresh each run (no per-figure deploy; repo-root
# ../deploy.sh installs global NOPASSWD + passwordless SSH).
RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
export RAPIDS0
export RAPIDS0_DIR="${RAPIDS0_DIR:-/home/$(whoami)/zcio-ae-9c}"
# /opt/rocksdb-env holds ONLY the binary + lib (environment); the run scripts
# (mount/make/read/rocksdb-run) live here in 9c. read_4disks/make_4disks call
# $ROCKSDB_BIN (default /opt/rocksdb-env/custom_rocksdb).
export ROCKSDB_BIN="${ROCKSDB_BIN:-/opt/rocksdb-env/custom_rocksdb}"
SSHOPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5"
CONFIGS=(${CONFIGS:-default zcIO})

pdu_for() { case "$1" in default) echo 0 ;; zcIO) echo 2 ;; *) echo "" ;; esac; }
zc_for()  { case "$1" in default) echo off ;; zcIO) echo on ;; *) echo "" ;; esac; }

# ----- preflight ------------------------------------------------------
echo ">>> preflight ..."
# (1) shared RocksDB env (binary + lib) provisioned in /opt ?
[[ -e "$ROCKSDB_BIN" ]] \
    || { echo "!! $ROCKSDB_BIN missing — it is pre-provisioned & shared on this machine; contact the maintainer"; exit 1; }
[[ -e "/opt/rocksdb-env/rocksdb-src/librocksdb.so.8.9" ]] \
    || { echo "!! librocksdb.so missing — pre-provisioned & shared on this machine; contact the maintainer"; exit 1; }
# local run scripts present
for f in mount_4disk.sh unmount_4disk.sh make_4disks.sh read_4disks.sh rocksdb-run.sh; do
    [[ -x "$HERE/$f" ]] || { echo "!! missing run script $HERE/$f"; exit 1; }
done
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
for cfg in "${CONFIGS[@]}"; do
    [[ -n "$(pdu_for "$cfg")" ]] || { echo "!! unknown config '$cfg' (use: default zcIO)"; exit 1; }
done

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

# Clear STALE result CSVs up front (both here and in the harness dir). Otherwise a
# config whose sweep fails would silently reuse a previous run's CSV and the
# combined table would print numbers that were never measured this run.
echo ">>> clearing stale result CSVs for: ${CONFIGS[*]}"
for cfg in "${CONFIGS[@]}"; do
    rm -f "./results-rocksdb-$cfg.csv"
done

# ----- per-config sweep -----------------------------------------------
for cfg in "${CONFIGS[@]}"; do
    PDU="$(pdu_for "$cfg")"; ZC="$(zc_for "$cfg")"
    echo
    echo "############################################################"
    echo "# config: $cfg   (ZCOPY=$ZC, nvme_pdu_align=$PDU)"
    echo "############################################################"

    # Clean slate: drop any lingering NVMe/TCP sessions so devices re-enumerate
    # deterministically for this config (avoids stale controllers / naming drift).
    echo ">>> [$cfg] disconnect any existing NVMe/TCP sessions first ..."
    ./disconnect.sh || echo "!! disconnect reported an error (continuing)"

    echo ">>> [$cfg] bringing up stack (setup.sh) ..."
    if ! NET_PDU="$PDU" ZCOPY="$ZC" ./setup.sh; then
        echo "!! setup failed for $cfg — skipping"; continue
    fi

    echo ">>> [$cfg] disks (mkfs+mount) + single-core RocksDB sweep ..."
    # One root session for the whole disk-prep + sweep (no mid-run sudo re-prompt).
    # PIN=offline: rocksdb-run.sh offlines cpu1+ for the single-core measurement
    # (restored on its EXIT). This figure measures SINGLE-core RocksDB IOPS.
    if ! sudo bash -c "cd '$HERE' && (./unmount_4disk.sh >/dev/null 2>&1 || true) && ./mount_4disk.sh && ./rocksdb-run.sh '$cfg' '' '' '' '' offline"; then
        echo "!! sweep failed for $cfg — continuing";
    fi
    # rocksdb-run.sh wrote results-rocksdb-$cfg.csv into $HERE (cwd) as root.
    if [[ -f "./results-rocksdb-$cfg.csv" ]]; then
        echo "   -> ./results-rocksdb-$cfg.csv"
    fi
done

# ----- combined report ------------------------------------------------
echo
echo "############################################################"
echo "# COMBINED: single-core RocksDB readrand IOPS (ops/s) by block size"
echo "############################################################"
python3 - "${CONFIGS[@]}" <<'PY'
import csv, os, sys
configs = sys.argv[1:]
order = ["4k","32k","64k","128k","256k"]
data = {}
for c in configs:
    p = f"results-rocksdb-{c}.csv"
    if not os.path.exists(p): continue
    data[c] = {}
    with open(p) as f:
        for row in csv.DictReader(f):
            if row.get("rep") == "avg":
                data[c][row["bs"]] = row["ops_per_s"]
present = [c for c in configs if c in data]
print("  ".join(f"{h:<14}" for h in ["bs"] + present))
for bs in order:
    print(f"{bs:<14}" + "  ".join(f"{data[c].get(bs,'-'):<14}" for c in present))
if "default" in data and "zcIO" in data:
    print("\nspeedup (zcIO/default):")
    for bs in order:
        try:
            d=float(data["default"][bs]); z=float(data["zcIO"][bs])
            print(f"  {bs:<6} {z/d:.2f}x")
        except (KeyError, ValueError, ZeroDivisionError): pass
PY

echo
echo ">>> plot ..."
python3 plot.py 2>/dev/null && echo "   -> results-plot.png / .pdf" || echo "   (plot.py skipped/failed)"

# ----- cleanup: unmount the 4 filesystems, then drop all NVMe/TCP sessions ----
echo
echo ">>> cleanup: unmount disks then nvme disconnect-all ..."
sudo bash -c "cd '$ROCKSDB_DIR' && ./unmount_4disk.sh" || echo "!! unmount reported an error (continuing)"
./disconnect.sh || echo "!! disconnect reported an error"

echo
echo "[all-in-one] done. Per-config CSVs: results-rocksdb-{${CONFIGS[*]// /,}}.csv"
echo "Disks unmounted + NVMe/TCP disconnected. Restore rapids0 baseline with: ./teardown.sh"
