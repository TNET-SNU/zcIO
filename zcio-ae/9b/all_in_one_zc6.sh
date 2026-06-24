#!/bin/bash
# all_in_one_zc6.sh — figure 9b: ONLY zcIO @ 6 cores (single point).
#
# Thin wrapper over all_in_one_full.sh with CONFIGS=zcIO, CORES=6. Reuses the full
# preflight / kernel-check / rapids0 staging / governor / datagen / cleanup /
# plot logic — only the config+core selection differs. Results in results-zc6/.
#
#   Usage:  ./all_in_one_zc6.sh
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
exec env CONFIGS="zcIO" CORES="6" OUTDIR="${OUTDIR:-results-zc6}" ./all_in_one_full.sh "$@"
