#!/bin/bash
# set-pdu-align.sh (stream5, write path) — set net.ipv4.nvme_pdu_align on the
# INITIATOR. On writes the initiator is the SENDER, so PDU-aligned packetization
# of the outgoing NVMe/TCP write data is controlled here (on the 5.15.189-pduwin
# kernel), mirroring what target-net-config.sh does on the target for reads.
#
#   Usage:  ./set-pdu-align.sh <0|2>
#     0 = baseline (linux / spdk)      2 = PDU-aligned (zcIO)
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
PDU="${1:?usage: set-pdu-align.sh <0|2>}"
if [[ ! -e /proc/sys/net/ipv4/nvme_pdu_align ]]; then
    echo "!! net.ipv4.nvme_pdu_align is absent — is stream5 on the 5.15.189-pduwin kernel? (uname -r: $(uname -r))" >&2
    exit 1
fi
sysctl -w "net.ipv4.nvme_pdu_align=${PDU}"
echo "[set-pdu-align] net.ipv4.nvme_pdu_align=$(sysctl -n net.ipv4.nvme_pdu_align)"
