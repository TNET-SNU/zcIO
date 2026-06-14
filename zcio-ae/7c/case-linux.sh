#!/bin/bash
# case-linux.sh — baseline "linux": target MTU 9000, TSO on, GSO off,
#                 nvme_pdu_align=0, initiator zero-copy OFF.
cd "$(dirname "$(readlink -f "$0")")"
./env-config.sh 9000 on off 0 || exit 1
./restore-tcp-config.sh         # undo SPDK's TCP tuning if it ran (no-op otherwise)
./zcopy_off.sh
