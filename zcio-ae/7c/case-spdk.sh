#!/bin/bash
# case-spdk.sh — SPDK baseline: target MTU 9000, TSO on, GSO off, nvme_pdu_align=0
# (same target baseline as "linux"). SPDK uses its own userspace NVMe/TCP
# initiator, so there's no kernel zero-copy toggle. Hugepages + controller attach
# happen in workload-spdk.sh.
cd "$(dirname "$(readlink -f "$0")")"
./env-config.sh 9000 on off 0 || exit 1
./set_tcp_config.sh             # SPDK needs the aggressive TCP tuning
