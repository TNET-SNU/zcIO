#!/bin/bash
# default_setup.sh — bring the fig-9b stack up to the COMPLETE DEFAULT-LINUX
# baseline, stopping right after `nvme connect` (no workload, no core limit).
#
#   stream5 : enable_zerocopy=0   (ZCOPY=off)
#   rapids0 : nvme_pdu_align=0     (NET_PDU=0)
#   -> 4 NVMe/TCP namespaces connected as /dev/nvmeXnY
#
# Both zero-copy knobs OFF = real default Linux. After this, run your own
# experiment by hand (mount_4disk.sh + your read scripts). Tear down: ./teardown.sh
#
# This is just setup.sh with the default knobs pinned, plus a clean disconnect
# first so devices re-enumerate deterministically.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

echo ">>> [default_setup] clean slate: disconnect any existing NVMe/TCP sessions"
./disconnect.sh || echo "!! disconnect reported an error (continuing)"

echo ">>> [default_setup] bringing up DEFAULT baseline (ZCOPY=off, nvme_pdu_align=0)"
exec env NET_PDU=0 ZCOPY=off ./setup.sh "$@"
