#!/bin/bash
# case-zcIO-MT.sh — "zcIO-MT": same target/zcopy as zcIO (MTU 9000, pdu_align=2,
# zero-copy ON); the only difference is the fio job uses threads (thread=1),
# selected via workload-256k-mt.fio in all-in-one.sh.
cd "$(dirname "$(readlink -f "$0")")"
./env-config.sh 9000 on off 2 || exit 1
./restore-tcp-config.sh         # undo SPDK TCP tuning if it ran (no-op otherwise)
./zcopy_on.sh
