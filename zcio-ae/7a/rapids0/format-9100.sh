#!/bin/bash
# format-9100.sh (rapids0) — clean, fresh-SLC START for a write benchmark: rebind
# every "Samsung SSD 9100 PRO" to the kernel nvme driver, nvme-format each one,
# wait for the SSDs to settle, then VERIFY they are actually clean (used ~0) before
# the run proceeds. Run ONCE at the start, BEFORE nvmet/SPDK binds the devices.
#
#   Env:  FMT_IDLE_SECS  (settle after format; default 30)
#         FMT_USED_MAX_GB(clean threshold in GB; default 1)
#         SKIP_FORMAT=1  (skip entirely)
#         SPDK_DIR       (default /opt/spdk)
# Model-gated to "9100 PRO" so the boot drive / other models are never touched.
set -uo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi

[[ -n "${SKIP_FORMAT:-}" ]] && { echo "[format-9100] SKIP_FORMAT set — skipping format"; exit 0; }
FMT_IDLE_SECS="${FMT_IDLE_SECS:-60}"
FMT_USED_MAX_GB="${FMT_USED_MAX_GB:-1}"
SPDK_DIR="${SPDK_DIR:-/opt/spdk}"
MODEL="9100 PRO"

# 1) make sure the SSDs are on the kernel nvme driver (a prior SPDK run leaves them
#    on vfio-pci, where nvme format can't reach them).
echo "[format-9100] rebind NVMe to kernel driver (setup.sh reset) ..."
"$SPDK_DIR/scripts/setup.sh" reset >/dev/null 2>&1 || true
echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
sleep 3

# 2) collect the 9100 PRO namespaces
DEVS=()
for ns in /dev/nvme[0-9]*n1; do
  [[ -b "$ns" ]] || continue
  nvme id-ctrl "$ns" 2>/dev/null | grep -q "$MODEL" && DEVS+=("$ns")
done
[[ ${#DEVS[@]} -gt 0 ]] || { echo "[format-9100] ERROR: no '$MODEL' namespaces found"; exit 1; }
echo "[format-9100] formatting ${#DEVS[@]} device(s): ${DEVS[*]}"

# 3) nvme format all in parallel (synchronous per device)
pids=()
for d in "${DEVS[@]}"; do
  ( nvme format "$d" --force >/dev/null 2>&1 && echo "  format $d : ok" \
      || echo "  format $d : FAILED" ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

# 4) wait for the SSDs to settle (background erase / controller quiesce)
echo "[format-9100] idle ${FMT_IDLE_SECS}s for the SSDs to settle ..."
sleep "$FMT_IDLE_SECS"

# 5) VERIFY each device is actually clean (used capacity below threshold); fail the
#    run if any device did not format, so we never start on a dirty/cliffed drive.
echo "[format-9100] verifying used capacity (clean if < ${FMT_USED_MAX_GB} GB):"
ok=1
mapfile -t ROWS < <(nvme list -o json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for x in d.get("Devices", []):
    m = x.get("ModelNumber","") or ""
    if "'"$MODEL"'" in m:
        print("%s\t%s" % (x.get("DevicePath",""), x.get("UsedBytes",0)))
')
[[ ${#ROWS[@]} -gt 0 ]] || { echo "[format-9100] ERROR: could not read used capacity"; exit 1; }
for row in "${ROWS[@]}"; do
  dev="${row%%$'\t'*}"; used="${row##*$'\t'}"
  gb=$(awk -v b="$used" 'BEGIN{printf "%.2f", b/1e9}')
  if awk -v b="$used" -v max="$FMT_USED_MAX_GB" 'BEGIN{exit !(b < max*1e9)}'; then
    echo "  $dev: used=${gb} GB  OK"
  else
    echo "  $dev: used=${gb} GB  !! NOT clean"; ok=0
  fi
done
[[ "$ok" -eq 1 ]] || { echo "[format-9100] some devices not clean — aborting"; exit 1; }
echo "[format-9100] all ${#DEVS[@]} devices clean & settled — ready to start."
