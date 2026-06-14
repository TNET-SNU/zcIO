#!/bin/bash
# zcopy_off.sh (rapids0, write path) — disable TARGET receive zero-copy (baseline
# "linux"). Clears the global net/ipv4/tcp_zc.c `enable_zerocopy` flag exposed at
# /sys/module/tcp_zc/parameters/enable_zerocopy.
# Run via NOPASSWD sudo over SSH (assumes already root).
set -uo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
P=/sys/module/tcp_zc/parameters/enable_zerocopy
[[ -e "$P" ]] || { echo "!! WARN: $P absent — is rapids0 on the target-zc kernel? ($(uname -r))" >&2; exit 0; }
echo 0 > "$P"
echo "[zcopy_off] $P = $(cat "$P")"
