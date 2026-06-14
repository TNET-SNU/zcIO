#!/bin/bash
# env-config.sh — apply ONE config's environment, both ends:
#   * TARGET (rapids0, over SSH): MTU / TSO / GSO / nvme_pdu_align on both NICs
#   * INITIATOR (stream5, local): the constant data-plane setup (stream5-net.sh)
#
# Only the target side varies between configs; stream5 is re-asserted (idempotent)
# so each case script is self-contained.
#
#   Usage:  ./env-config.sh <mtu> <tso:on|off> <gso:on|off> <pdu_align:0|1>
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

MTU="${1:?mtu}"; TSO="${2:?tso}"; GSO="${3:?gso}"; PDU="${4:?pdu_align}"

# rapids0 control plane (management SSH). Override via env if needed.
RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
# Inherited (exported) from all_in_one.sh; this fallback only applies if run standalone.
RAPIDS0_DIR="${RAPIDS0_DIR:-/home/fast27/zcio-ae-8}"
SSH="ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 $RAPIDS0"

echo ">>> [target rapids0] net-config: MTU=$MTU TSO=$TSO GSO=$GSO pdu_align=$PDU"
$SSH sudo -n "$RAPIDS0_DIR/target-net-config.sh" "$MTU" "$TSO" "$GSO" "$PDU"

echo ">>> [initiator stream5] net-config (constant: MTU 9000, TSO/GSO/GRO/rx-hw-gro on)"
./stream5-net.sh

sleep 2   # let both links settle after MTU/offload changes
