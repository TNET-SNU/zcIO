#!/bin/bash
# stream5-net.sh (fig-7c) — initiator data-plane setup. Reloads mlx5 first so
# hardware GRO can be (re)enabled reliably even after the cpu-limit flap left it
# stuck "off [requested on]". Fixed NIC mapping:
#
#   ens2np0 -> 10.3.95.5/24   (reaches target ens17np0 @ 10.3.95.10)
#   ens3np0 -> 10.3.96.5/24   (reaches target ens19np0 @ 10.3.96.10)
#
# Recipe (bring the link UP first, enable hw-gro LAST):
#   modprobe -r mlx5_ib mlx5_core ; modprobe mlx5_core mlx5_ib
#   then per NIC:
#     ifconfig <if> mtu 1500
#     ifconfig <if> <ip>/<prefix> up         # up at 1500 (link comes up)
#     ifconfig <if> mtu 9000                 # bump (hw-gro still off -> ok)
#     ip route replace <net>/<prefix> dev <if> proto kernel scope link src <ip>
#     ethtool -K <if> rx-gro-hw off ; ethtool -K <if> rx-gro-hw on tso on gro on
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

reload_mlx5() {
  echo "[stream5-net] reloading mlx5 (unload mlx5_ib+mlx5_core -> load core, ib)"
  modprobe -r mlx5_ib mlx5_core 2>/dev/null || \
    modprobe -r mlx5_ib mlx5_vdpa mlx5_fwctl mlx5_core 2>/dev/null || true
  modprobe mlx5_core mlx5_ib
  # wait for both netdevs to re-enumerate
  local entry iface ok i
  for i in $(seq 1 30); do
    ok=1
    for entry in "${NICS[@]}"; do iface="${entry%%|*}"; [[ -e "/sys/class/net/$iface" ]] || ok=0; done
    [[ "$ok" -eq 1 ]] && { echo "  NICs back after ${i}s"; break; }
    sleep 1
  done
  sleep 2
}

apply_nic() {  # iface cidr
  local iface="$1" cidr="$2" ip="${2%/*}" prefix="${2#*/}"
  [[ -e "/sys/class/net/${iface}" ]] || { echo "  WARN: ${iface} not present"; return 1; }
  # Working order: bring the link UP at the default MTU 1500, enable hw-gro there
  # (off->on; off first clears the "off [requested on]" stuck state — hw-gro fits
  # the RQ at 1500), THEN bump MTU to 9000 (the RQ reconfigs to jumbo keeping
  # hw-gro). Enabling hw-gro at 9000, or before the up, fails (E2BIG / stuck).
  ip addr flush dev "$iface" 2>/dev/null || true
  ifconfig "$iface" "${ip}/${prefix}" up
  # link is up -> ensure the on-link subnet route (idempotent; /24 here).
  ip route replace "${ip%.*}.0/${prefix}" dev "$iface" proto kernel scope link src "$ip" \
      || echo "    WARN: route add failed for $iface (is the IP up?)"
  ethtool -K "$iface" rx-gro-hw off 2>/dev/null || true
  ethtool -K "$iface" rx-gro-hw on            # hw-gro at MTU 1500
  ifconfig "$iface" mtu "$MTU"                # then bump to 9000 (hw-gro stays on)
  ethtool -K "$iface" tso on gro on
  ethtool -G "$iface" rx 4096 tx 8192   # NIC ring buffers (after mlx5 reload, before traffic)

  local hwgro mtu state
  hwgro=$(ethtool -k "$iface" 2>/dev/null | awk -F': ' '/^rx-gro-hw:/{print $2}')
  mtu=$(cat /sys/class/net/${iface}/mtu)
  state=$(cat /sys/class/net/${iface}/operstate 2>/dev/null)
  echo "  ${iface}: state=${state} mtu=${mtu} rx-gro-hw=${hwgro}"
  echo "    addr : $(ip -br -4 addr show "$iface" 2>/dev/null | sed 's/  */ /g')"
  echo "    route: $(ip route show dev "$iface" 2>/dev/null | paste -sd' ' -)"
}

reload_mlx5
for entry in "${NICS[@]}"; do
  IFS='|' read -r iface cidr tgt <<< "$entry"
  apply_nic "$iface" "$cidr"
done

echo 1 > /proc/sys/net/ipv4/tcp_no_metrics_save

echo "[stream5-net] interfaces:"
ip -br addr show | grep -E "10\.3\.(95|96)\.5" || true

sleep 1
for entry in "${NICS[@]}"; do
  IFS='|' read -r iface cidr tgt <<< "$entry"
  if ping -c1 -W1 -I "$iface" "$tgt" >/dev/null 2>&1; then
    echo "[stream5-net] $iface -> $tgt : OK"
  else
    echo "[stream5-net] $iface -> $tgt : UNREACHABLE (check cabling/target NIC)"
  fi
done
