#!/bin/bash
# baseline-sweep.sh — run ONLY the "linux" baseline config across the core sweep,
# to isolate where the full run gets stuck (zero-copy off, fio processes).
# Thin wrapper over all-in-one.sh (just pins CONFIGS=linux).
#
#   ./baseline-sweep.sh                          # cores 1 2 4 8 12 15, full prep+restore
#   CORES="1 2 4" ./baseline-sweep.sh            # narrow the core list
#   SKIP_PREP=1 SKIP_RESTORE=1 ./baseline-sweep.sh   # fast re-iterate (target already up)
#
# Watch the per-step logs (">>> ===== config=linux cores=N =====", then
# cpu-limit / stream5-net / workload) to see which core count / step stalls.
cd "$(dirname "$(readlink -f "$0")")"
CONFIGS="linux" exec ./all-in-one.sh "$@"
