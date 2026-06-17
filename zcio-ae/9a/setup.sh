#!/bin/bash
# setup.sh — fig-9a (MLPerf Storage + RocksDB) common environment setup.
#
# Brings the testbed to the state every fig-9a workload assumes, and STOPS there:
#
#   [target rapids0]  is up with the NVMe/TCP nvmet target exporting 4 drives
#                     on ONE 400 GbE NIC (ens17np0 @ 10.3.95.10), at FULL cores.
#   [initiator stream5] has those 4 namespaces connected as /dev/nvmeXn1.
#
# It does NOT run MLPerf or RocksDB — point your own workload scripts
# (/mlperf_test/mlperf_storage/test, ~/rocksdb_test) at the connected devices
# afterwards. This setup leaves the COMPLETE DEFAULT-LINUX baseline:
# BOTH zero-copy knobs OFF — rapids0 nvme_pdu_align=0 (target/sender) AND
# stream5 enable_zerocopy=0 (initiator/receiver). For the zcIO data point flip
# both: ./zcopy_on.sh here + NET_PDU=2 (see README). Leaving enable_zerocopy=1
# while reading is what corrupts concurrent O_DIRECT reads, so the baseline must
# force it to 0 — which this script now does.
#
# Sequence (mirrors fig-7c's case-linux baseline, minus the 1-core limit and
# the per-config sweep):
#   [stream5]  buffer.sh -> stream5-net.sh -> zcopy_off.sh   (enable_zerocopy=0)
#   [rapids0]  nvmet teardown -> net baseline(pdu_align=0) -> buffer.sh
#              -> nvmet-9100 -> cpu governor=performance     (all at FULL cores)
#   [stream5]  connect.sh   (4 subsystems on .95.10)
#
# Requires the NOPASSWD sudoers installed by ./deploy.sh on both hosts.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
RAPIDS0_DIR="${RAPIDS0_DIR:-$HOME/zcio-ae-9a}"
SSH="ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 $RAPIDS0"

# fig-9a: 4 drives as 4 namespaces under ONE subsystem -> ONE controller / TCP
# connection (with connect.sh -i 1 => ONE I/O queue total). NQN must match
# nvmet-9100.sh's SINGLE_NQN.
FIG9A_NQN="${FIG9A_NQN:-nvmet-ens17np0-fig9a}"

# Target-side network baseline (default Linux):  MTU  TSO  GSO  nvme_pdu_align.
# NET_PDU=0 is the default-Linux sender path; set NET_PDU=2 for the zcIO point.
NET_MTU="${NET_MTU:-9000}"; NET_TSO="${NET_TSO:-on}"; NET_GSO="${NET_GSO:-off}"; NET_PDU="${NET_PDU:-0}"

# Initiator receive zero-copy: ZCOPY=off (default Linux) | on (zcIO). Pair it with
# NET_PDU — zcIO = ZCOPY=on + NET_PDU=2; default = ZCOPY=off + NET_PDU=0. Mixing
# them (zcopy on + pdu 0) corrupts concurrent O_DIRECT reads.
ZCOPY="${ZCOPY:-off}"
case "$ZCOPY" in on|off) ;; *) echo "ZCOPY must be on|off (got '$ZCOPY')"; exit 1 ;; esac

# ----- preflight ------------------------------------------------------
echo ">>> preflight: checking NOPASSWD sudo on both hosts ..."
sudo -n -l "$(pwd)/connect.sh" >/dev/null 2>&1 \
    || { echo "!! stream5 NOPASSWD missing for connect.sh — run ./deploy.sh first"; exit 1; }
$SSH sudo -n -l "$RAPIDS0_DIR/nvmet-9100.sh" >/dev/null 2>&1 \
    || { echo "!! rapids0 NOPASSWD missing — run ./deploy.sh first (RAPIDS0_DIR=$RAPIDS0_DIR)"; exit 1; }

# ----- initiator (stream5) data NIC FIRST -----------------------------
echo
echo ">>> [initiator stream5] buffer.sh (64MiB socket buffers + NIC rings)"
./buffer.sh || echo "!! stream5 buffer.sh failed (continuing)"
echo ">>> [initiator stream5] stream5-net.sh (ens2np0=10.3.95.5, ens3np0=10.3.96.5, MTU 9000)"
./stream5-net.sh || { echo "!! stream5 net setup failed"; exit 1; }
echo ">>> [initiator stream5] zcopy_${ZCOPY}.sh (enable_zerocopy=$([[ $ZCOPY == on ]] && echo 1 || echo 0))"
"./zcopy_${ZCOPY}.sh" || echo "!! zcopy_${ZCOPY} failed (continuing — check enable_zerocopy!)"

# ----- target (rapids0) bring-up at FULL cores ------------------------
echo
echo ">>> [target rapids0] nvmet teardown (clean slate)"
$SSH sudo -n "$RAPIDS0_DIR/nvmet-9100-teardown.sh" || { echo "!! teardown failed"; exit 1; }

echo ">>> [target rapids0] net baseline: MTU=$NET_MTU TSO=$NET_TSO GSO=$NET_GSO pdu_align=$NET_PDU"
$SSH sudo -n "$RAPIDS0_DIR/target-net-config.sh" "$NET_MTU" "$NET_TSO" "$NET_GSO" "$NET_PDU" \
    || { echo "!! target net baseline failed"; exit 1; }

echo ">>> [target rapids0] buffer.sh (64MiB socket buffers + NIC rings)"
$SSH sudo -n "$RAPIDS0_DIR/buffer.sh" || echo "!! buffer.sh failed (continuing)"
sleep 2

echo ">>> [target rapids0] nvmet-9100.sh --single-subsys (4 drives = 4 ns in ONE subsystem)"
$SSH sudo -n "$RAPIDS0_DIR/nvmet-9100.sh" --no-ipsetup --single-subsys || { echo "!! nvmet-9100 setup failed"; exit 1; }

echo ">>> [target rapids0] CPU governor -> performance"
$SSH sudo -n "$RAPIDS0_DIR/cpu-governor.sh" performance || echo "!! cpu-governor performance failed (continuing)"

# ----- initiator connects ONE subsystem (4 namespaces) ----------------
# No -i: with cpu offlined to 1 before connect, the kernel's default queue count
# (= num_online_cpus = 1) gives ONE I/O queue for the single controller = all 4 disks.
echo
echo ">>> [initiator stream5] connecting ONE subsystem ($FIG9A_NQN) = 4 namespaces @ 10.3.95.10"
./connect.sh --expect 4 "$FIG9A_NQN" || { echo "!! connect failed"; exit 1; }

echo
echo "############################################################"
echo "# fig-9a setup complete  (COMPLETE DEFAULT-LINUX baseline)."
echo "#   target  : $RAPIDS0  (nvmet up, full cores, nvme_pdu_align=$NET_PDU)"
echo "#   stream5 : enable_zerocopy=$(cat /sys/module/nvme_tcp/parameters/enable_zerocopy 2>/dev/null)"
echo "#   devices : connected above as /dev/nvmeXn1"
echo "#"
echo "# Next: run your workload (NOT part of setup):"
echo "#   MLPerf  -> /mlperf_test/mlperf_storage/test/<script>"
echo "#   RocksDB -> ~/rocksdb_test/<script>"
echo "# Tear down with:  ./teardown.sh"
echo "############################################################"
