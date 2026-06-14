#!/bin/bash
# buffer.sh — stream5 (initiator) socket-buffer tuning (64 MiB), mirroring the
# target's buffer.sh. NIC rings are NOT set here in fig-7c: stream5-net.sh
# reloads mlx5 (which resets rings), so it sets the 8192 rings itself on the
# fresh driver, before enabling hw-gro.
#
#   Usage:  sudo ./buffer.sh
set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

sysctl -w net.core.rmem_max=67108864
sysctl -w net.core.wmem_max=67108864
sysctl -w net.ipv4.tcp_rmem='4096 1048576 67108864'
sysctl -w net.ipv4.tcp_wmem='4096 1048576 67108864'

echo "[buffer] stream5: 64MiB socket buffers (NIC rings set by stream5-net.sh)"
