#!/bin/bash
# require-hwgro.sh — assert rx-gro-hw is ON for both stream5 data NICs (the zcIO
# case needs hardware GRO for receive zero-copy to work). If it's off, re-run
# stream5-net.sh once (which retries the down/up + hw-gro-first sequence); if it
# still won't enable, exit non-zero so the run stops instead of producing a
# misleading "zcIO" number with hw-gro off.
#
# Reads ethtool unprivileged; only stream5-net.sh (self-sudo) needs root.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

NICS=(ens2np0 ens3np0)

hwgro_on() {
  local i
  for i in "${NICS[@]}"; do
    [[ "$(ethtool -k "$i" 2>/dev/null | awk -F': ' '/^rx-gro-hw:/{print $2}')" == on ]] || return 1
  done
  return 0
}

if ! hwgro_on; then
  echo "[require-hwgro] rx-gro-hw not on — re-running stream5-net.sh"
  ./stream5-net.sh
  sleep 2
fi

if hwgro_on; then
  echo "[require-hwgro] OK: rx-gro-hw on for ${NICS[*]}"
else
  echo "[require-hwgro] ERROR: rx-gro-hw could NOT be enabled on ${NICS[*]} — zcIO requires it" >&2
  exit 1
fi
