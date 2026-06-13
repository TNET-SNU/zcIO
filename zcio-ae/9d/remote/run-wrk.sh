#!/bin/bash
# run-wrk.sh <server_ip> <threads> <conns> <duration> <timeout>
# Runs ON the client (creek1). Fires 4 parallel wrk (one per /remoteN), sums the
# Transfer/sec across all four, and prints a machine-readable TOTAL line.
set -uo pipefail
SERVER_IP="${1:?server ip}"
THREADS="${2:-2}"
CONNS="${3:-3}"
DURATION="${4:-30s}"
TIMEOUT="${5:-10s}"
WARMUP="${6:-0s}"        # warmup duration, results discarded. 0/0s = skip. all_in_one passes $WRK_WARMUP.
WRK="${WRK_BIN:-wrk}"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# sanity: files reachable?
for n in 1 2 3 4; do
  curl -fsS -I "http://$SERVER_IP/remote$n/video/test.mp4" >/dev/null 2>&1 \
    || echo "WARN: /remote$n not reachable" >&2
done

# warmup (results discarded): let page-cache/connections/governor reach steady state
if [ "$WARMUP" != "0" ] && [ "$WARMUP" != "0s" ]; then
  echo ">> warmup: t=$THREADS c=$CONNS d=$WARMUP (x4 parallel, discarded)"
  for n in 1 2 3 4; do
    "$WRK" -t"$THREADS" -c"$CONNS" -d"$WARMUP" --timeout "$TIMEOUT" \
        "http://$SERVER_IP/remote$n/video/test.mp4" >/dev/null 2>&1 &
  done
  wait
fi

echo ">> wrk: t=$THREADS c=$CONNS d=$DURATION (x4 parallel)"
for n in 1 2 3 4; do
  "$WRK" -t"$THREADS" -c"$CONNS" -d"$DURATION" --timeout "$TIMEOUT" \
      "http://$SERVER_IP/remote$n/video/test.mp4" > "$OUT/res_remote$n.log" 2>&1 &
done
wait

python3 - "$OUT" <<'PY'
import re, sys, glob, os
d = sys.argv[1]
def parse_bw(txt):
    m = re.search(r'Transfer/sec:\s+([\d.]+)([KMG]?B)', txt)
    if not m: return 0.0
    v=float(m.group(1)); u=m.group(2)
    return {'B':v/1e9,'KB':v/1e6,'MB':v/1e3,'GB':v}.get(u,0.0)
def parse_req(txt):
    m = re.search(r'Requests/sec:\s+([\d.]+)', txt)
    return float(m.group(1)) if m else 0.0
total_gb=0.0; total_rps=0.0
for f in sorted(glob.glob(os.path.join(d,"res_remote*.log"))):
    t=open(f).read()
    bw=parse_bw(t); rps=parse_req(t)
    total_gb+=bw; total_rps+=rps
    print(f"  {os.path.basename(f)}: {bw:.3f} GB/s  {rps:.1f} req/s")
print(f"TOTAL_GBPS={total_gb:.3f}")
print(f"TOTAL_RPS={total_rps:.1f}")
PY
