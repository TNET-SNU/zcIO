#!/bin/bash
# zcopy_on.sh (rapids0, write path) — enable TARGET receive zero-copy (zcIO).
# On the 6.11.0-target-zc-add-frozen+ kernel the toggle is the global
# net/ipv4/tcp_zc.c `enable_zerocopy` module param (built-in, so it shows up at
# /sys/module/tcp_zc/parameters/enable_zerocopy). nvmet-tcp gates its zero-copy
# receive path on this single flag; there are no rx_zc_batch_* knobs on the
# target (those are host/initiator-side nvme_tcp params).
# Run via NOPASSWD sudo over SSH (assumes already root).
set -uo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
P=/sys/module/tcp_zc/parameters/enable_zerocopy
[[ -e "$P" ]] || { echo "!! WARN: $P absent — is rapids0 on the target-zc kernel? ($(uname -r))" >&2; exit 0; }
echo 1 > "$P"
echo "[zcopy_on] $P = $(cat "$P")"
