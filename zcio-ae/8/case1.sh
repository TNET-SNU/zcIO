#!/bin/bash
# case1.sh — target MTU 1500, TSO off, GSO off, nvme_pdu_align=0
#            (E2E MTU = min(9000, 1500) = 1500)
cd "$(dirname "$(readlink -f "$0")")"
exec ./env-config.sh 1500 off off 0
