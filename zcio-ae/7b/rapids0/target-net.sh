#!/bin/bash
# target-net.sh (rapids0, write path) — TARGET data-plane setup, mirror of the
# initiator stream5-net.sh. Reloads mlx5 first so hardware GRO can be (re)enabled
# reliably even after a cpu-limit flap, then brings up both target data NICs at
# MTU 9000 with hw-gro/tso/gro on. On writes the TARGET is the RECEIVER, so its
# rx-gro-hw must be on for the zcIO receive zero-copy path.
#
#   ens17np0 -> 10.3.95.10/24   (reaches initiator ens2np0 @ 10.3.95.5)
#   ens19np0 -> 10.3.96.10/24   (reaches initiator ens3np0 @ 10.3.96.5)
#
# Run via NOPASSWD sudo over SSH (assumes already root). MUST run at full cores,
# BEFORE connecting the subsystems — it reloads mlx5 (which would drop live
# NVMe/TCP connections). Do NOT run it between core-sweep steps.
set -uo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi

# iface | cidr | initiator-IP-to-ping
NICS=(
  "ens17np0|10.3.95.10/24|10.3.95.5"
  "ens19np0|10.3.96.10/24|10.3.96.5"
)
MTU=9000

reload_mlx5() {
  echo "[target-net] reloading mlx5 (unload mlx5_ib+mlx5_core -> load core, ib)"
  nvme disconnect-all >/dev/null 2>&1 || true
  modprobe -r mlx5_ib mlx5_core 2>/dev/null || \
    modprobe -r mlx5_ib mlx5_vdpa mlx5_fwctl mlx5_core 2>/dev/null || true
  modprobe mlx5_core mlx5_ib
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
  ip addr flush dev "$iface" 2>/dev/null || true
  ifconfig "$iface" "${ip}/${prefix}" up
  ip route replace "${ip%.*}.0/${prefix}" dev "$iface" proto kernel scope link src "$ip" \
      || echo "    WARN: route add failed for $iface (is the IP up?)"
  ethtool -K "$iface" rx-gro-hw off 2>/dev/null || true
  ethtool -K "$iface" rx-gro-hw on            # hw-gro at MTU 1500
  ifconfig "$iface" mtu "$MTU"                # then bump to 9000 (hw-gro stays on)
  ethtool -K "$iface" tso on gro on

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

echo "[target-net] interfaces:"
ip -br addr show | grep -E "10\.3\.(95|96)\.10" || true

sleep 1
for entry in "${NICS[@]}"; do
  IFS='|' read -r iface cidr tgt <<< "$entry"
  if ping -c1 -W1 -I "$iface" "$tgt" >/dev/null 2>&1; then
    echo "[target-net] $iface -> $tgt : OK"
  else
    echo "[target-net] $iface -> $tgt : UNREACHABLE (check cabling/initiator NIC)"
  fi
done
