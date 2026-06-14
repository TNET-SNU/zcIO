#!/bin/bash
# spdk-target-stop.sh (rapids0) — stop the SPDK NVMe-oF target and hand the NVMe
# SSDs back to the kernel driver, so the kernel nvmet configs (linux/zcIO) can run
# afterwards. Run via NOPASSWD sudo over SSH (assumes already root).
set -uo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
SPDK_DIR="${SPDK_DIR:-/opt/spdk}"

# NOTE: SPDK renames its main thread comm to "reactor_0", so `pkill nvmf_tgt`
# (which matches comm) MISSES it — must match the full cmdline with -f.
if pgrep -f '/nvmf_tgt' >/dev/null 2>&1; then
  echo "[spdk-stop] killing nvmf_tgt"
  pkill -9 -f '/nvmf_tgt' || true
  for _ in $(seq 1 20); do pgrep -f '/nvmf_tgt' >/dev/null 2>&1 || break; sleep 0.5; done
  pgrep -f '/nvmf_tgt' >/dev/null 2>&1 && echo "  !! WARN: nvmf_tgt still alive after kill" || echo "  nvmf_tgt gone"
fi
# unbind from vfio-pci, return NVMe devices to the kernel nvme driver
if [[ -x "$SPDK_DIR/scripts/setup.sh" ]]; then
  echo "[spdk-stop] setup.sh reset (rebind NVMe to kernel)"
  "$SPDK_DIR/scripts/setup.sh" reset 2>/dev/null || true
  sleep 3
fi
echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
sleep 2
echo "[spdk-stop] kernel NVMe controllers now: $(ls /sys/class/nvme 2>/dev/null | paste -sd' ' -)"
