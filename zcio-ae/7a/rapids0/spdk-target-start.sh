#!/bin/bash
# spdk-target-start.sh (rapids0) — launch the SPDK NVMe-oF TCP target detached so
# it survives the SSH session that started it. /opt/spdk_target.sh backgrounds
# nvmf_tgt and exits after configuring it via RPC; we run the whole thing under
# setsid (new session, no controlling terminal) with stdio redirected to a log so
# nvmf_tgt keeps running after we return. The caller (stream5) then polls
# `nvme discover` until the subsystems are live before connecting.
#
#   Usage:  ./spdk-target-start.sh <num_cores>   (core count == SPDK core mask)
# Run via NOPASSWD sudo over SSH (assumes already root).
set -uo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
# lift the locked-memory cap so large SPDK iobuf pools (num_shared_buffers ×
# io_unit_size) can be allocated; root can raise its own hard limit. Propagates
# to nvmf_tgt (launched as a child). Falls back gracefully if not permitted.
ulimit -l unlimited 2>/dev/null || ulimit -l 134217728 2>/dev/null || true
echo "[spdk-start] memlock limit: $(ulimit -l)"
N="${1:?usage: spdk-target-start.sh <num_cores>}"
SPDK_TARGET="${SPDK_TARGET:-/opt/spdk_target.sh}"
LOG="/tmp/spdk_target_${N}.log"
[[ -x "$SPDK_TARGET" ]] || { echo "ERROR: $SPDK_TARGET not found/executable" >&2; exit 1; }

# kill any prior instance first (core mask is fixed at launch -> must restart to
# change cores). SPDK renames its main thread comm to "reactor_0", so we must
# match the full cmdline (-f), not the comm, or the old instance survives and
# holds the core lock ("Cannot create lock on core 0").
pkill -9 -f '/nvmf_tgt' 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -f '/nvmf_tgt' >/dev/null 2>&1 || break; sleep 0.5; done
rm -f /var/tmp/spdk_cpu_lock_* 2>/dev/null || true
sleep 1

# ---- fresh-SLC: nvme-format the 9100 PRO target SSDs before SPDK binds them ----
# Clean state for fresh-SLC (burst) write benchmarking, and clears any stale FS
# signature that would make SPDK refuse to vfio-bind the device. Devices must be
# on the kernel nvme driver to format, so rebind from vfio first (a prior SPDK
# run leaves them on vfio); /opt/spdk_target.sh re-binds to vfio afterwards.
# Model-gated to "9100 PRO" so the boot drive is never touched. Skip: SKIP_FORMAT=1.
if [[ -z "${SKIP_FORMAT:-}" ]]; then
  SPDK_DIR="${SPDK_DIR:-/opt/spdk}"
  echo "[spdk-start] fresh-SLC: rebind to kernel + nvme format 9100 PRO SSDs"
  "$SPDK_DIR/scripts/setup.sh" reset >/dev/null 2>&1 || true
  sleep 3
  for ns in /dev/nvme[0-9]*n1; do
    [[ -b "$ns" ]] || continue
    if nvme id-ctrl "$ns" 2>/dev/null | grep -q "9100 PRO"; then
      printf '  nvme format %s ... ' "$ns"
      nvme format "$ns" --force >/dev/null 2>&1 && echo "ok" || echo "FAILED"
    fi
  done
fi

# Run setup in the FOREGROUND so we return ONLY after every subsystem exists. If we
# returned early (detached), the caller's connect would race subsystem creation and
# trip "Unable to add ns, subsystem in active state" (partial target). nvmf_tgt is
# launched with setsid INSIDE spdk_target.sh, so it survives this script's exit.
"$SPDK_TARGET" "$N" >"$LOG" 2>&1
echo "[spdk-start] $SPDK_TARGET $N setup complete; nvmf_tgt detached. log: $LOG"
