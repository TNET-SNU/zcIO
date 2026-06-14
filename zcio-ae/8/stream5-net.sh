#!/bin/bash
# stream5-net.sh — initiator (stream5) data-plane setup. CONSTANT for every
# config. Fixed NIC mapping (per the cabling to rapids0):
#
#   ens2np0 -> 10.3.95.5/24   (reaches target ens17np0 @ 10.3.95.10)
#   ens3np0 -> 10.3.96.5/24   (reaches target ens19np0 @ 10.3.96.10)
#
# Both NICs: MTU 9000, then TSO/GSO/GRO/rx-gro-hw on in a single ethtool -K
# (works from a clean post-boot RQ state). stream5 stays MTU 9000 always, so the
# end-to-end MTU = min(9000, target) is set by the target alone.
#
#   Usage:  sudo ./stream5-net.sh
set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi

# iface | cidr | target-IP-to-ping
NICS=(
  "ens2np0|10.3.95.5/24|10.3.95.10"
  "ens3np0|10.3.96.5/24|10.3.96.10"
)
MTU=9000

apply_nic() {  # iface cidr
  local iface="$1" cidr="$2" ip="${2%/*}" prefix="${2#*/}"
  [[ -e "/sys/class/net/${iface}" ]] || { echo "  WARN: ${iface} not present"; return 1; }

  # Verified working recipe (from a clean post-boot RQ state):
  #   ifconfig <iface> <ip>/<prefix> up
  #   ifconfig <iface> mtu 9000
  #   ethtool -K <iface> rx-gro-hw on tso on gso on gro on
  # NIC ring buffers are set earlier by buffer.sh (run before this script); the
  # bring-up recipe below works fine with rings already at 8192.
  ip addr flush dev "$iface" 2>/dev/null || true
  ifconfig "$iface" "${ip}/${prefix}" up
  ifconfig "$iface" mtu "$MTU"
  ethtool -K "$iface" rx-gro-hw on tso on gso on gro on

  local hwgro
  hwgro=$(ethtool -k "$iface" 2>/dev/null | awk -F': ' '/^rx-gro-hw:/{print $2}')
  echo "  ${iface}: mtu=$(cat /sys/class/net/${iface}/mtu) rx-gro-hw=${hwgro}"
}

for entry in "${NICS[@]}"; do
  IFS='|' read -r iface cidr tgt <<< "$entry"
  apply_nic "$iface" "$cidr"
done

# Socket-buffer sysctls + NIC rings are owned by buffer.sh (run before this).
echo 1 > /proc/sys/net/ipv4/tcp_no_metrics_save

echo "[stream5-net] interfaces:"
ip -br addr show | grep -E "10\.3\.(95|96)\.5" || true

# Connectivity check (warn-only; the mapping is fixed by cabling).
sleep 1
for entry in "${NICS[@]}"; do
  IFS='|' read -r iface cidr tgt <<< "$entry"
  if ping -c1 -W1 -I "$iface" "$tgt" >/dev/null 2>&1; then
    echo "[stream5-net] $iface -> $tgt : OK"
  else
    echo "[stream5-net] $iface -> $tgt : UNREACHABLE (check cabling/target NIC)"
  fi
done
