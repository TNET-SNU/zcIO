#!/usr/bin/env bash
# target-net-config.sh — per-config network state for the NVMe/TCP TARGET (rapids0).
# Applies MTU / TSO / GSO / nvme_pdu_align to BOTH data NICs, then re-asserts
# their data-plane IPs (a NIC reset or MTU bounce can drop them).
#
# Deployed to $RAPIDS0_DIR (default $HOME/zcio-ae-9a, root-owned) and
# run via NOPASSWD sudo from stream5's setup.sh over SSH.
#
#   Usage:  sudo ./target-net-config.sh <mtu> <tso:on|off> <gso:on|off> <pdu_align:0|1>
#
#   pdu_align: net.ipv4.nvme_pdu_align controls PDU-aligned packetization of the
#   NVMe/TCP data the TARGET sends out (the read path), so it changes the wire
#   behaviour even for read workloads.
set -uo pipefail

if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi

MTU="${1:?mtu}"
TSO="${2:?tso on|off}"
GSO="${3:?gso on|off}"
PDU="${4:?pdu_align 0|1}"

# Both target NICs and the data-plane IP each must keep (see nvmet-9100.sh).
NIC1_IFACE="ens17np0"; NIC1_IP="10.3.95.10"; NIC1_PREFIX="24"
NIC2_IFACE="ens19np0"; NIC2_IP="10.3.96.10"; NIC2_PREFIX="24"

cfg_nic() {  # iface ip prefix
  local iface="$1" ip="$2" prefix="$3"
  [[ -e "/sys/class/net/${iface}" ]] || { echo "  ${iface}: absent, skip"; return 0; }

  ip link set "${iface}" up
  ip link set "${iface}" mtu "${MTU}"
  ethtool -K "${iface}" tso "${TSO}" gso "${GSO}" || true

  # MTU/up bounces can flush the address; re-add if missing.
  if ! ip -4 addr show dev "${iface}" | grep -qw "${ip}/${prefix}"; then
    ip addr add "${ip}/${prefix}" dev "${iface}" || true
  fi

  local cur_tso cur_gso
  cur_tso=$(ethtool -k "${iface}" | awk -F': ' '/^tcp-segmentation-offload:/{print $2}')
  cur_gso=$(ethtool -k "${iface}" | awk -F': ' '/^generic-segmentation-offload:/{print $2}')
  echo "  ${iface}: mtu=$(cat /sys/class/net/${iface}/mtu) tso=${cur_tso} gso=${cur_gso} ip=${ip}/${prefix}"
}

echo "[target-net-config] MTU=${MTU} TSO=${TSO} GSO=${GSO} pdu_align=${PDU}"
cfg_nic "${NIC1_IFACE}" "${NIC1_IP}" "${NIC1_PREFIX}"
cfg_nic "${NIC2_IFACE}" "${NIC2_IP}" "${NIC2_PREFIX}"

sysctl -w "net.ipv4.nvme_pdu_align=${PDU}"
echo "[target-net-config] done."
