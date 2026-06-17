#!/bin/bash
# buffer.sh — stream5 (initiator) socket-buffer + NIC-ring tuning. Mirrors the
# target's rapids0/buffer.sh so both ends use the same 64 MiB socket
# buffers and 8192-entry NIC rings. Run BEFORE stream5-net.sh (rings must be set
# before the bring-up recipe enables hw-gro).
#
#   Usage:  sudo ./buffer.sh
set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

NICS=(ens2np0 ens3np0)

sysctl -w net.core.rmem_max=67108864
sysctl -w net.core.wmem_max=67108864
sysctl -w net.ipv4.tcp_rmem='4096 1048576 67108864'
sysctl -w net.ipv4.tcp_wmem='4096 1048576 67108864'

for i in "${NICS[@]}"; do
  [[ -e "/sys/class/net/$i" ]] && ethtool -G "$i" rx 4096 tx 8192 || true
done

echo "[buffer] stream5: 64MiB socket buffers + rings rx4096/tx8192 on ${NICS[*]}"
