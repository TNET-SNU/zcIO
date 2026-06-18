#!/bin/bash
# measure-host.sh (initiator, write path) — run ONE fio random-write point across
# THIS host's connected NVMe/TCP devices and report fio's OWN measured write
# throughput (ramp_time excluded by fio). Used on BOTH initiators; all_in_one runs
# the two concurrently and SUMS the two .result files into the figure's summary.
#
# Why fio's result (not NIC tx_bytes sampling): with two hosts running
# concurrently, whichever fio finishes first leaves the other briefly alone on the
# target, and a per-second tx_bytes CoV window can latch onto that spike -> inflated
# "steady" numbers. fio's average over a fixed runtime (after ramp_time) is the
# contended, ramp-excluded throughput we actually want.
#
#   Usage:  ./measure-host.sh <out_dir> <label> <fiofile> [nic_ip]
#     nic_ip : optional, for the log line only (this host's data-NIC IPv4).
#   Env:  RAMP_SECS (10)  RUNTIME_SECS (30)  IDLE_SECS (12)  WSET_SIZE (10G, per-dev randwrite span)
#
# Writes <out_dir>/<label>.result :  "<gbps> <cov_pct> <fio_MiBps> <fio_kIOPS> <fio_clat_us>"
# and    <out_dir>/<label>.json   :  raw fio json.   Self-execs via sudo -n.
set -uo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -n "$SCRIPT_PATH" "$@"; fi
cd "$(dirname "$SCRIPT_PATH")"

OUT="${1:?usage: measure-host.sh <out_dir> <label> <fiofile> [nic_ip]}"
LABEL="${2:?label}"
FIOFILE="${3:?fiofile}"
NIC_IP="${4:-}"

RAMP_SECS="${RAMP_SECS:-10}"        # excluded from fio's reported result
RUNTIME_SECS="${RUNTIME_SECS:-30}"  # measured (steady) window length
IDLE_SECS="${IDLE_SECS:-12}"        # post-blkdiscard idle (SLC drain / GC quiesce)
WSET_SIZE="${WSET_SIZE:-10G}"       # randwrite working-set per device: confine to SLC -> stable SLC-speed

[[ -f "$FIOFILE" ]] || { echo "  ERROR: fio param file '$FIOFILE' not found"; exit 1; }
mkdir -p "$OUT"
chown -R "${SUDO_USER:-root}" "$OUT" 2>/dev/null || true
RESULT="$OUT/$LABEL.result"
rm -f "$RESULT"

# discover all NVMe/TCP namespace block devices on THIS host (kernel nvmet + SPDK;
# handles nvme_core.multipath=Y where the path is nvmeXcYn1 and the head is nvmeXn1).
DEVS=()
declare -A _seen
for c in /sys/class/nvme/nvme*; do
  [[ -r "$c/transport" ]] || continue
  [[ "$(cat "$c/transport" 2>/dev/null)" == tcp ]] || continue
  for ns in "$c"/nvme*n*; do
    [[ -e "$ns" ]] || continue
    head="$(basename "$ns" | sed -E 's/c[0-9]+n/n/')"
    # Guard: a regular file at the device path means a prior fio created it while
    # the node was absent (fio auto-creates missing filenames). Benchmarking that
    # = page-cached file, NOT the device -> bogus numbers. Fail loudly.
    if [[ -e "/dev/$head" && ! -b "/dev/$head" ]]; then
      echo "ERROR: /dev/$head is NOT a block device (stray fio-created file). Fix: sudo rm -f /dev/$head, then reconnect." >&2
      exit 1
    fi
    [[ -b "/dev/$head" ]] || continue
    [[ -n "${_seen[$head]:-}" ]] && continue
    _seen[$head]=1; DEVS+=("/dev/$head")
  done
done
[[ ${#DEVS[@]} -gt 0 ]] || { echo "ERROR: no NVMe/TCP devices (connect first)"; exit 1; }
echo "[measure-host] $(hostname) label=$LABEL  ${#DEVS[@]} devs: ${DEVS[*]}  (${NIC_IP:-NIC n/a})  ramp=${RAMP_SECS}s run=${RUNTIME_SECS}s"

# fresh-SLC: blkdiscard each device + idle so the SSD starts uncliffed.
echo "[measure-host] reset SSD cache: blkdiscard ${#DEVS[@]} devs (parallel) + ${IDLE_SECS}s idle"
for d in "${DEVS[@]}"; do
  ( blkdiscard "$d" >/dev/null 2>&1 && echo "  blkdiscard $d: ok" \
      || echo "  !! blkdiscard $d FAILED (discard unsupported?)" ) &
done
wait
sleep "$IDLE_SECS"

# Build the job: copy the [global] template, FORCE ramp_time/runtime/time_based and
# size (the randwrite working-set per device — confine to SLC for stable SLC-speed;
# fio job-file [global] can override command-line, so edit the file), then append
# one [devN] per device.
job="$(mktemp)"
sed -E -e "s/^ramp_time=.*/ramp_time=${RAMP_SECS}/" \
       -e "s/^runtime=.*/runtime=${RUNTIME_SECS}s/" \
       -e "s/^time_based=.*/time_based=1/" \
       -e "s/^size=.*/size=${WSET_SIZE}/" "$FIOFILE" > "$job"
grep -q '^ramp_time='  "$job" || sed -i "0,/^\[global\]/s//[global]\nramp_time=${RAMP_SECS}/"      "$job"
grep -q '^runtime='    "$job" || sed -i "0,/^\[global\]/s//[global]\nruntime=${RUNTIME_SECS}s/"     "$job"
grep -q '^time_based=' "$job" || sed -i "0,/^\[global\]/s//[global]\ntime_based=1/"                 "$job"
grep -q '^size='       "$job" || sed -i "0,/^\[global\]/s//[global]\nsize=${WSET_SIZE}/"            "$job"
i=0; for d in "${DEVS[@]}"; do printf '\n[dev%d]\nfilename=%s\n' "$i" "$d" >> "$job"; i=$((i+1)); done

# Run fio to completion (let it own its ramp+runtime); watchdog kills a hung run.
fio "$job" --output-format=json --output="$OUT/$LABEL.json" 2>"$OUT/$LABEL.err" &
fpid=$!
deadline=$(( RAMP_SECS + RUNTIME_SECS + 60 ))
for _ in $(seq 1 "$deadline"); do kill -0 "$fpid" 2>/dev/null || break; sleep 1; done
if kill -0 "$fpid" 2>/dev/null; then
    echo "  !! fio exceeded ${deadline}s — killing"
    kill -TERM "$fpid" 2>/dev/null || true; sleep 2; pkill -9 -x fio 2>/dev/null || true
fi
wait "$fpid" 2>/dev/null || true
rm -f "$job"

python3 - "$OUT/$LABEL.json" "$RESULT" "$(hostname)" "$LABEL" <<'PY'
import json, sys, math
jf, result, host, label = sys.argv[1:]
gbps = cov = mbps = kiops = clat = 0.0
try:
    raw = open(jf).read()
    jobs = json.loads(raw[raw.index('{'):])['jobs']
    bw_kibs = 0.0; bw_dev2 = 0.0; clats = []
    for jb in jobs:
        wr = jb['write']
        bw_kibs += wr.get('bw', 0)            # KiB/s
        bw_dev2 += wr.get('bw_dev', 0) ** 2   # combine per-job stddevs
        kiops   += wr.get('iops', 0) / 1000.0
        c = wr.get('clat_ns', wr.get('lat_ns', {})).get('mean', 0)
        if c: clats.append(c)
    gbps  = bw_kibs * 1024.0 / 1e9            # KiB/s -> bytes/s -> GB/s (decimal)
    mbps  = bw_kibs / 1024.0                  # -> MiB/s
    cov   = (math.sqrt(bw_dev2) / bw_kibs * 100.0) if bw_kibs > 0 else 0.0
    clat  = (sum(clats)/len(clats)/1000.0) if clats else 0.0
except Exception as e:
    sys.stderr.write("parse error: %s\n" % e)
print("  [%s] fio write: %.4f GB/s  (%.0f MiB/s, %.1f kIOPS, clat %.1f us, bwCoV %.2f%%)"
      % (host, gbps, mbps, kiops, clat, cov))
open(result,'w').write(f"{gbps:.4f} {cov:.2f} {mbps:.1f} {kiops:.1f} {clat:.1f}\n")
PY
chown "${SUDO_USER:-root}" "$RESULT" 2>/dev/null || true
