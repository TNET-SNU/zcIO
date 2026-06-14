#!/bin/bash
# case-zcIO-MP.sh — "zcIO (MP)": multi-PROCESS zcIO. Same target/zcopy as zcIO-MT
#                   (MTU 9000, pdu_align=2, zero-copy ON); fio uses processes
#                   (workload-zcIO-MP-<N>.fio, no thread=1).
# (stream5 net + require-hwgro run per core count in all-in-one.sh, not here.)
cd "$(dirname "$(readlink -f "$0")")"
./env-config.sh 9000 on off 2 || exit 1
./restore-tcp-config.sh         # undo SPDK TCP tuning if it ran (no-op otherwise)
./zcopy_on.sh
