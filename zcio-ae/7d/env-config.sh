#!/bin/bash
# env-config.sh — apply ONE config's TARGET-side environment (rapids0, over SSH):
# MTU / TSO / GSO / nvme_pdu_align on both target NICs.
#
# The stream5 (initiator) data plane is set ONCE in all-in-one.sh's prep
# (buffer.sh + stream5-net.sh, which reloads mlx5) — NOT per case — so we don't
# reload the driver for every config. case-zcIO.sh re-verifies hw-gro separately.
#
#   Usage:  ./env-config.sh <mtu> <tso:on|off> <gso:on|off> <pdu_align:0|1|2>
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

MTU="${1:?mtu}"; TSO="${2:?tso}"; GSO="${3:?gso}"; PDU="${4:?pdu_align}"

RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
RAPIDS0_DIR="${RAPIDS0_DIR:-/home/fast27/zcio-ae-7d}"
SSH="ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 $RAPIDS0"

echo ">>> [target rapids0] net-config: MTU=$MTU TSO=$TSO GSO=$GSO pdu_align=$PDU"
$SSH sudo -n "$RAPIDS0_DIR/target-net-config.sh" "$MTU" "$TSO" "$GSO" "$PDU"

sleep 2   # let the target links settle after MTU/offload changes
