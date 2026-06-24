#!/bin/bash
# config.sh — figure 9b knobs.  >>> EDIT HERE <<<  to change GPUs / threads / cores.
# Sourced by sweep-unet3d.sh, so all_in_one.sh / all_in_one_full.sh / _zc6.sh all pick it up.
# Env vars still override (e.g.  NUM_ACCEL=6 THREAD_MULT=1 ./all_in_one.sh).

CONFIGS="${CONFIGS:-default zcIO}"   # which modes to run:  "default"  |  "zcIO"  |  "default zcIO"
NUM_ACCEL="${NUM_ACCEL:-8}"          # simulated GPUs (accelerators)
THREAD_MULT="${THREAD_MULT:-1}"      # reader threads per GPU = THREAD_MULT * online_cores
CORES="${CORES:-1 2 4 6 8 10}"       # full-sweep online-core points (all_in_one.sh uses a fixed 3-point list; _zc6 overrides)

# usually leave these alone:
NUM_FILES="${NUM_FILES:-3072}"       # dataset size (keep divisible by NUM_ACCEL: 3072 = 8*384 = 6*512)
MEM_GB="${MEM_GB:-36}"               # --client-host-memory-in-gb
