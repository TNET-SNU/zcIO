#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# nvmet setup for 2x 400G NICs, 4x Samsung 9100 PRO per NIC (8 subsystems)
#
#   ens17np0 (10.3.95.10/24) -> nvme6n1, nvme7n1, nvme8n1, nvme9n1
#   ens19np0 (10.3.96.10/24) -> nvme2n1, nvme3n1, nvme4n1, nvme5n1
#
# NQN naming: nvmet-<iface>-<dev>   (e.g. nvmet-ens17np0-nvme6n1)
# All subsystems exported on TCP/RDMA port 4420. One configfs port per
# (NIC, transport): a single kernel listener serves all 4 subsystems on
# that NIC. Port ids:
#   tcp:   NIC1=1, NIC2=2
#   rdma:  NIC1=3, NIC2=4   (rdma-only mode reuses 1,2)
#
# Usage:
#   sudo ./nvmet-9100.sh [--transport tcp|rdma|both] [--no-ipsetup] [--reset]
# ----------------------------------------------------------------------------

ADR_FAM="ipv4"
TRSVCID="4420"

NIC1_IFACE="ens17np0"
NIC1_IP="10.3.95.10"
NIC1_PREFIX="24"

NIC2_IFACE="ens19np0"
NIC2_IP="10.3.96.10"
NIC2_PREFIX="24"

# device | iface | ip
DEVICES=(
  "/dev/nvme6n1|${NIC1_IFACE}|${NIC1_IP}"
  "/dev/nvme7n1|${NIC1_IFACE}|${NIC1_IP}"
  "/dev/nvme8n1|${NIC1_IFACE}|${NIC1_IP}"
  "/dev/nvme9n1|${NIC1_IFACE}|${NIC1_IP}"
  "/dev/nvme2n1|${NIC2_IFACE}|${NIC2_IP}"
  "/dev/nvme3n1|${NIC2_IFACE}|${NIC2_IP}"
  "/dev/nvme4n1|${NIC2_IFACE}|${NIC2_IP}"
  "/dev/nvme5n1|${NIC2_IFACE}|${NIC2_IP}"
)

CONFIGFS="/sys/kernel/config"
NVMET_BASE="${CONFIGFS}/nvmet"

TRANSPORT="tcp"
SETUP_IP=1
DO_RESET=0

usage() {
  cat <<EOF
Usage: $0 [--transport tcp|rdma|both] [--no-ipsetup] [--reset]

  --transport tcp     Export every subsystem over TCP only (default)
  --transport rdma    Export every subsystem over RDMA only
  --transport both    Export every subsystem over both TCP and RDMA
  --no-ipsetup        Skip assigning IPs to NICs
  --reset             Tear down existing nvmet config before applying
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --transport)    TRANSPORT="$2"; shift 2 ;;
    --transport=*)  TRANSPORT="${1#*=}"; shift ;;
    --no-ipsetup)   SETUP_IP=0; shift ;;
    --reset)        DO_RESET=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

case "${TRANSPORT}" in
  tcp|rdma|both) ;;
  *) echo "Invalid --transport: ${TRANSPORT}"; usage; exit 1 ;;
esac

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo bash $0"
    exit 1
  fi
}

load_modules() {
  modprobe nvmet
  case "${TRANSPORT}" in
    tcp)
      modprobe nvmet-tcp 2>/dev/null || modprobe nvmet_tcp
      ;;
    rdma)
      modprobe nvmet-rdma 2>/dev/null || modprobe nvmet_rdma
      ;;
    both)
      modprobe nvmet-tcp  2>/dev/null || modprobe nvmet_tcp
      modprobe nvmet-rdma 2>/dev/null || modprobe nvmet_rdma
      ;;
  esac
}

mount_configfs() {
  mkdir -p "${CONFIGFS}"
  if ! mountpoint -q "${CONFIGFS}"; then
    mount -t configfs none "${CONFIGFS}"
  fi
}

setup_ip() {
  local iface="$1" ip="$2" prefix="$3"
  if [[ ! -e "/sys/class/net/${iface}" ]]; then
    echo "Interface ${iface} not present, skipping IP setup"
    return 0
  fi
  ip link set "${iface}" up
  if ! ip -4 addr show dev "${iface}" | grep -qw "${ip}/${prefix}"; then
    echo "Assigning ${ip}/${prefix} to ${iface}"
    ip addr add "${ip}/${prefix}" dev "${iface}"
  fi
}

write_attr() {
  local value="$1" path="$2"
  printf '%s' "${value}" | tee "${path}" >/dev/null
}

reset_nvmet() {
  echo "Resetting existing nvmet configuration..."
  [[ -d "${NVMET_BASE}" ]] || return 0

  if [[ -d "${NVMET_BASE}/ports" ]]; then
    for p in "${NVMET_BASE}/ports/"*; do
      [[ -d "$p" ]] || continue
      if [[ -d "$p/subsystems" ]]; then
        for s in "$p/subsystems/"*; do
          [[ -L "$s" ]] && rm -f "$s"
        done
      fi
      rmdir "$p" 2>/dev/null || true
    done
  fi

  if [[ -d "${NVMET_BASE}/subsystems" ]]; then
    for s in "${NVMET_BASE}/subsystems/"*; do
      [[ -d "$s" ]] || continue
      if [[ -d "$s/namespaces" ]]; then
        for n in "$s/namespaces/"*; do
          [[ -d "$n" ]] || continue
          [[ -e "$n/enable" ]] && write_attr "0" "$n/enable" || true
          rmdir "$n" 2>/dev/null || true
        done
      fi
      rmdir "$s" 2>/dev/null || true
    done
  fi
}

create_subsystem() {
  local dev="$1" nqn="$2"
  local subsys_dir="${NVMET_BASE}/subsystems/${nqn}"
  local ns_dir="${subsys_dir}/namespaces/1"

  mkdir -p "${subsys_dir}"
  write_attr "1" "${subsys_dir}/attr_allow_any_host"

  mkdir -p "${ns_dir}"
  # device_path is locked once enable=1; only write while disabled
  if [[ "$(cat "${ns_dir}/enable" 2>/dev/null || echo 0)" != "1" ]]; then
    write_attr "${dev}" "${ns_dir}/device_path"
    write_attr "1"      "${ns_dir}/enable"
  fi
}

create_port() {
  local portid="$1" trtype="$2" ip="$3"
  local port_dir="${NVMET_BASE}/ports/${portid}"
  mkdir -p "${port_dir}"

  for f in addr_trtype addr_adrfam addr_traddr addr_trsvcid; do
    [[ -e "${port_dir}/${f}" ]] || { echo "Missing ${port_dir}/${f} (transport module not loaded?)"; exit 1; }
  done

  # Port attrs are frozen once any subsystem is linked. Only write if no links yet.
  if ! compgen -G "${port_dir}/subsystems/*" >/dev/null; then
    write_attr "${trtype}"  "${port_dir}/addr_trtype"
    write_attr "${ADR_FAM}" "${port_dir}/addr_adrfam"
    write_attr "${ip}"      "${port_dir}/addr_traddr"
    write_attr "${TRSVCID}" "${port_dir}/addr_trsvcid"
  fi
}

link_sub_to_port() {
  local portid="$1" nqn="$2"
  local port_dir="${NVMET_BASE}/ports/${portid}"
  local subsys_dir="${NVMET_BASE}/subsystems/${nqn}"
  mkdir -p "${port_dir}/subsystems"
  [[ -L "${port_dir}/subsystems/${nqn}" ]] || ln -s "${subsys_dir}" "${port_dir}/subsystems/${nqn}"
}

FMT_THRESHOLD_BYTES="${FMT_THRESHOLD_BYTES:-1000000000}"   # 1 GB

# nvme-format every "Samsung SSD 9100 PRO" namespace whose used capacity exceeds
# FMT_THRESHOLD_BYTES, for a fresh-SLC benchmark start (matches the SPDK path,
# which formats before binding). Without this the kernel-nvmet path leaves the
# drives dirty -> 256k randwrite hits GC/RMW -> high iowait + write-cliff (e.g.
# linux 15-core dropping 24 -> 13 GB/s). Model-gated: the boot drive and any
# other model are never touched. Skip with SKIP_FORMAT=1.
format_dirty_9100() {
  command -v python3 >/dev/null 2>&1 || { echo "  (python3 missing — skip usage check)"; return 0; }
  echo "Formatting dirty 9100 PRO namespaces (used > $((FMT_THRESHOLD_BYTES/1000000000)) GB)..."
  local dev used model
  while IFS=$'\t' read -r dev used model; do
    [[ -b "$dev" ]] || continue
    if (( used > FMT_THRESHOLD_BYTES )); then
      echo "  ${dev}: used=${used} B (${model}) — nvme format"
      nvme format "${dev}" --force >/dev/null 2>&1 && echo "    formatted" || echo "    WARN: nvme format ${dev} failed"
    else
      echo "  ${dev}: used=${used} B — clean, skip"
    fi
  done < <(nvme list -o json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for x in d.get("Devices", []):
    m = x.get("ModelNumber", "") or ""
    if "9100 PRO" in m:
        print("%s\t%s\t%s" % (x.get("DevicePath", ""), x.get("UsedBytes", 0), m))
')
}

main() {
  need_root
  load_modules
  mount_configfs

  [[ "${DO_RESET}" -eq 1 ]] && reset_nvmet

  # fresh-SLC: format any 9100 PRO that still has data, before exporting it
  [[ -n "${SKIP_FORMAT:-}" ]] || format_dirty_9100

  if [[ "${SETUP_IP}" -eq 1 ]]; then
    setup_ip "${NIC1_IFACE}" "${NIC1_IP}" "${NIC1_PREFIX}"
    setup_ip "${NIC2_IFACE}" "${NIC2_IP}" "${NIC2_PREFIX}"
  fi

  mkdir -p "${NVMET_BASE}/subsystems" "${NVMET_BASE}/ports"

  # One configfs port per (NIC, transport). The kernel opens exactly one
  # listener per port, so reusing a single port for all subsystems on the
  # same NIC avoids EADDRINUSE on the shared (trtype, traddr, trsvcid).
  case "${TRANSPORT}" in
    tcp)
      create_port 1 "tcp" "${NIC1_IP}"
      create_port 2 "tcp" "${NIC2_IP}"
      ;;
    rdma)
      create_port 1 "rdma" "${NIC1_IP}"
      create_port 2 "rdma" "${NIC2_IP}"
      ;;
    both)
      create_port 1 "tcp"  "${NIC1_IP}"
      create_port 2 "tcp"  "${NIC2_IP}"
      create_port 3 "rdma" "${NIC1_IP}"
      create_port 4 "rdma" "${NIC2_IP}"
      ;;
  esac

  for entry in "${DEVICES[@]}"; do
    IFS='|' read -r dev iface ip <<< "${entry}"

    if [[ ! -b "${dev}" ]]; then
      echo "Block device not found: ${dev}"; exit 1
    fi

    local nqn="nvmet-${iface}-$(basename "${dev}")"
    echo "Subsystem ${nqn}  dev=${dev}  ip=${ip}:${TRSVCID}  transport=${TRANSPORT}"
    create_subsystem "${dev}" "${nqn}"

    local nic_idx
    if [[ "${iface}" == "${NIC1_IFACE}" ]]; then nic_idx=1; else nic_idx=2; fi

    case "${TRANSPORT}" in
      tcp|rdma)
        link_sub_to_port "${nic_idx}" "${nqn}"
        ;;
      both)
        link_sub_to_port "${nic_idx}"       "${nqn}"   # tcp  port  (1 or 2)
        link_sub_to_port "$((nic_idx + 2))" "${nqn}"   # rdma port  (3 or 4)
        ;;
    esac
  done

  echo
  echo "Done. transport=${TRANSPORT}"
  echo "Initiator examples:"
  for entry in "${DEVICES[@]}"; do
    IFS='|' read -r dev iface ip <<< "${entry}"
    local nqn="nvmet-${iface}-$(basename "${dev}")"
    case "${TRANSPORT}" in
      tcp|both)  echo "  nvme connect -t tcp  -n ${nqn} -a ${ip} -s ${TRSVCID}" ;;
    esac
    case "${TRANSPORT}" in
      rdma|both) echo "  nvme connect -t rdma -n ${nqn} -a ${ip} -s ${TRSVCID}" ;;
    esac
  done
}

main "$@"
