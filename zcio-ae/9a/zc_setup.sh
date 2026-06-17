#!/bin/bash
# zc_setup.sh — bring the fig-9a stack up to the zcIO config, stopping right
# after `nvme connect` (no workload, no core limit).
#
#   stream5 : enable_zerocopy=1   (ZCOPY=on)
#   rapids0 : nvme_pdu_align=2     (NET_PDU=2)
#   -> 4 NVMe/TCP namespaces connected as /dev/nvmeXnY
#
# Both zero-copy knobs ON = zcIO (must be paired; zcopy-on with pdu=0 corrupts
# concurrent O_DIRECT reads). After this, run your own experiment by hand
# (mount_4disk.sh + your read scripts). Tear down: ./teardown.sh
#
# This is just setup.sh with the zcIO knobs pinned, plus a clean disconnect
# first so devices re-enumerate deterministically.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

echo ">>> [zc_setup] clean slate: disconnect any existing NVMe/TCP sessions"
./disconnect.sh || echo "!! disconnect reported an error (continuing)"

echo ">>> [zc_setup] bringing up zcIO config (ZCOPY=on, nvme_pdu_align=2)"
exec env NET_PDU=2 ZCOPY=on ./setup.sh "$@"
