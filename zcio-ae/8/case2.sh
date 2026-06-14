#!/bin/bash
# case2.sh — target MTU 9000, TSO off, GSO off, nvme_pdu_align=0
cd "$(dirname "$(readlink -f "$0")")"
exec ./env-config.sh 9000 off off 0
