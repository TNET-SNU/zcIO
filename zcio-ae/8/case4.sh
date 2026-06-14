#!/bin/bash
# case4.sh — target MTU 9000, TSO on, GSO off, nvme_pdu_align=1
#            (pdu_align=1: target emits PDU-aligned NVMe/TCP data on the read path)
cd "$(dirname "$(readlink -f "$0")")"
exec ./env-config.sh 9000 on off 1
