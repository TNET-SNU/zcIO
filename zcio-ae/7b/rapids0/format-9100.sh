#!/bin/bash
# format-9100.sh (rapids0) — clean, fresh-SLC START for a write benchmark: rebind
# every "Samsung SSD 9100 PRO" to the kernel nvme driver, nvme-format each one, then
# settle + VERIFY they are actually clean (used ~0) before the run proceeds. Instead
# of a fixed long wait, it waits FMT_IDLE_SECS, verifies, and RETRIES the wait up to
# FMT_MAX_TRIES (so a clean drive proceeds after one short wait; a laggy one gets
# more time). Run ONCE at the start, BEFORE nvmet/SPDK binds the devices.
#
#   Env:  FMT_IDLE_SECS   (settle per try; default 30)
#         FMT_MAX_TRIES   (verify attempts; default 3 = 1 + 2 retries)
#         FMT_USED_MAX_GB (clean threshold in GB; default 1)
#         SKIP_FORMAT=1   (skip entirely)
#         SPDK_DIR        (default /opt/spdk)
# Model-gated to "9100 PRO" so the boot drive / other models are never touched.
set -uo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "run as root" >&2; exit 1; fi

[[ -n "${SKIP_FORMAT:-}" ]] && { echo "[format-9100] SKIP_FORMAT set — skipping format"; exit 0; }
FMT_IDLE_SECS="${FMT_IDLE_SECS:-30}"
FMT_MAX_TRIES="${FMT_MAX_TRIES:-3}"
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

# verify helper: 0 if EVERY 9100 PRO is below the used threshold (i.e. clean)
verify_clean() {
  local row dev used gb ok=1
  local rows=()
  mapfile -t rows < <(nvme list -o json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for x in d.get("Devices", []):
    m = x.get("ModelNumber","") or ""
    if "'"$MODEL"'" in m:
        print("%s\t%s" % (x.get("DevicePath",""), x.get("UsedBytes",0)))
')
  [[ ${#rows[@]} -gt 0 ]] || { echo "  (could not read used capacity)"; return 1; }
  for row in "${rows[@]}"; do
    dev="${row%%$'\t'*}"; used="${row##*$'\t'}"
    gb=$(awk -v b="$used" 'BEGIN{printf "%.2f", b/1e9}')
    if awk -v b="$used" -v max="$FMT_USED_MAX_GB" 'BEGIN{exit !(b < max*1e9)}'; then
      echo "  $dev: used=${gb} GB  OK"
    else
      echo "  $dev: used=${gb} GB  !! not clean yet"; ok=0
    fi
  done
  [[ "$ok" -eq 1 ]]
}

# 4) settle FMT_IDLE_SECS then verify; if not clean, wait again (up to FMT_MAX_TRIES).
clean=0
for ((try=1; try<=FMT_MAX_TRIES; try++)); do
  echo "[format-9100] settle ${FMT_IDLE_SECS}s, then verify (try ${try}/${FMT_MAX_TRIES}) ..."
  sleep "$FMT_IDLE_SECS"
  if verify_clean; then clean=1; break; fi
  [[ "$try" -lt "$FMT_MAX_TRIES" ]] && echo "[format-9100] not clean — waiting another ${FMT_IDLE_SECS}s ..."
done
[[ "$clean" -eq 1 ]] || { echo "[format-9100] still not clean after ${FMT_MAX_TRIES} tries — aborting"; exit 1; }
echo "[format-9100] all ${#DEVS[@]} devices clean & settled — ready to start."
