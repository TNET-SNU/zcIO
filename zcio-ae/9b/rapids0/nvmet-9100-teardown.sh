#!/usr/bin/env bash
set -uo pipefail

# ----------------------------------------------------------------------------
# Tear down nvmet configuration (all subsystems & ports).
#
# Usage:
#   sudo ./nvmet-9100-teardown.sh                 # remove all nvmet config
#   sudo ./nvmet-9100-teardown.sh --unload        # also rmmod nvmet modules
#   sudo ./nvmet-9100-teardown.sh --down-ip       # also flush NIC IPs we set
# ----------------------------------------------------------------------------

CONFIGFS="/sys/kernel/config"
NVMET_BASE="${CONFIGFS}/nvmet"

NIC1_IFACE="ens17np0"
NIC1_IP="10.3.95.10"
NIC1_PREFIX="24"

NIC2_IFACE="ens19np0"
NIC2_IP="10.3.96.10"
NIC2_PREFIX="24"

UNLOAD=0
DOWN_IP=0

usage() {
  cat <<EOF
Usage: $0 [--unload] [--down-ip]

  --unload   rmmod nvmet_tcp / nvmet_rdma / nvmet after teardown
  --down-ip  Remove the IPs that nvmet-9100.sh added to the NICs
  -h, --help Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unload)   UNLOAD=1; shift ;;
    --down-ip)  DOWN_IP=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

write_attr() {
  printf '%s' "$1" | tee "$2" >/dev/null 2>&1 || true
}

if [[ ! -d "${NVMET_BASE}" ]]; then
  echo "nvmet configfs not present at ${NVMET_BASE}, nothing to tear down"
else
  echo "Unlinking subsystems from ports..."
  if [[ -d "${NVMET_BASE}/ports" ]]; then
    for p in "${NVMET_BASE}/ports/"*; do
      [[ -d "$p" ]] || continue
      if [[ -d "$p/subsystems" ]]; then
        for s in "$p/subsystems/"*; do
          [[ -L "$s" ]] || continue
          echo "  rm ${s}"
          rm -f "$s"
        done
      fi
    done
  fi

  echo "Removing ports..."
  if [[ -d "${NVMET_BASE}/ports" ]]; then
    for p in "${NVMET_BASE}/ports/"*; do
      [[ -d "$p" ]] || continue
      echo "  rmdir ${p}"
      rmdir "$p" 2>/dev/null || echo "    (failed; check $p)"
    done
  fi

  echo "Disabling and removing namespaces / subsystems..."
  if [[ -d "${NVMET_BASE}/subsystems" ]]; then
    for s in "${NVMET_BASE}/subsystems/"*; do
      [[ -d "$s" ]] || continue
      if [[ -d "$s/namespaces" ]]; then
        for n in "$s/namespaces/"*; do
          [[ -d "$n" ]] || continue
          [[ -e "$n/enable" ]] && write_attr "0" "$n/enable"
          echo "  rmdir ${n}"
          rmdir "$n" 2>/dev/null || echo "    (failed; check $n)"
        done
      fi
      if [[ -d "$s/allowed_hosts" ]]; then
        for h in "$s/allowed_hosts/"*; do
          [[ -L "$h" ]] && rm -f "$h"
        done
      fi
      echo "  rmdir ${s}"
      rmdir "$s" 2>/dev/null || echo "    (failed; check $s)"
    done
  fi

  echo "Removing hosts (if any)..."
  if [[ -d "${NVMET_BASE}/hosts" ]]; then
    for h in "${NVMET_BASE}/hosts/"*; do
      [[ -d "$h" ]] || continue
      rmdir "$h" 2>/dev/null || true
    done
  fi
fi

if [[ "${UNLOAD}" -eq 1 ]]; then
  echo "Unloading nvmet modules..."
  for m in nvmet_tcp nvmet_rdma nvme_loop nvmet; do
    if lsmod | awk '{print $1}' | grep -qx "$m"; then
      echo "  rmmod $m"
      rmmod "$m" 2>/dev/null || echo "    (still in use; check 'lsmod | grep $m')"
    fi
  done
fi

if [[ "${DOWN_IP}" -eq 1 ]]; then
  echo "Flushing IPs added by nvmet-9100.sh..."
  for pair in "${NIC1_IFACE}|${NIC1_IP}/${NIC1_PREFIX}" "${NIC2_IFACE}|${NIC2_IP}/${NIC2_PREFIX}"; do
    IFS='|' read -r iface cidr <<< "$pair"
    if [[ -e "/sys/class/net/${iface}" ]] && ip -4 addr show dev "${iface}" | grep -qw "${cidr}"; then
      echo "  ip addr del ${cidr} dev ${iface}"
      ip addr del "${cidr}" dev "${iface}" || true
    fi
  done
fi

echo "Done."
