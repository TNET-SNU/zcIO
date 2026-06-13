#!/bin/bash
# case-zcIO.sh — "zcIO": target MTU 9000, TSO on, GSO off, nvme_pdu_align=2
#                (target emits PDU-aligned data) + initiator zero-copy ON.
cd "$(dirname "$(readlink -f "$0")")"
./env-config.sh 9000 on off 2 || exit 1
./restore-tcp-config.sh          # undo SPDK's TCP tuning if it ran (no-op otherwise)
./require-hwgro.sh || exit 1     # zcIO requires hardware GRO on the initiator
./zcopy_on.sh
