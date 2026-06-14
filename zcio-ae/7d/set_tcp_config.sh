#!/bin/bash
# set_tcp_config.sh — apply SPDK's TCP tuning (run before the SPDK workload).
# SPDK needs these. Saves the CURRENT values ONCE to a state file first, so
# restore-tcp-config.sh can revert them for the kernel (linux/zcIO) configs.
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

SAVE="${TCP_SAVE:-/tmp/zcio-tcp-config.saved}"
KEYS=(net.core.busy_poll net.core.busy_read net.core.somaxconn
      net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog
      net.core.rmem_max net.core.wmem_max net.ipv4.tcp_mem
      net.ipv4.tcp_rmem net.ipv4.tcp_wmem vm.overcommit_memory)

# Save pre-SPDK baseline ONCE (so re-running set never clobbers the true baseline).
if [[ ! -f "$SAVE" ]]; then
  : > "$SAVE"
  for k in "${KEYS[@]}"; do
    v="$(sysctl -n "$k" 2>/dev/null)" || continue
    v="${v//$'\t'/ }"                       # tabs -> spaces for sysctl -p
    printf '%s = %s\n' "$k" "$v" >> "$SAVE"
  done
  echo "[set-tcp] saved current values -> $SAVE"
fi

sysctl -qw net.core.busy_poll=0
sysctl -qw net.core.busy_read=0
sysctl -qw net.core.somaxconn=4096
sysctl -qw net.core.netdev_max_backlog=8192
sysctl -qw net.ipv4.tcp_max_syn_backlog=16384
sysctl -qw net.core.rmem_max=268435456
sysctl -qw net.core.wmem_max=268435456
sysctl -qw net.ipv4.tcp_mem="268435456 268435456 268435456"
sysctl -qw net.ipv4.tcp_rmem="8192 1048576 33554432"
sysctl -qw net.ipv4.tcp_wmem="8192 1048576 33554432"
sysctl -qw net.ipv4.route.flush=1
sysctl -qw vm.overcommit_memory=1
echo "[set-tcp] SPDK TCP config applied"
