#!/bin/bash
# measure-2host.sh — run ONE 2-initiator write point BY HAND and SUM both hosts.
# For manual measurement when the SPDK/kernel target is already up and both hosts
# are already connected (you ran connect-targets yourself). It runs measure-host.sh
# on stream5 (local, .96) and stream6 (over SSH, .95) CONCURRENTLY, then sums their
# fio write BW. measure-host.sh does the fresh-SLC blkdiscard + idle itself.
#
#   Usage:  ./measure-2host.sh <label> <fiofile>
#     e.g.  ./measure-2host.sh 15 workload-spdk-15.fio
#
#   Env (passed through to measure-host.sh): WSET_SIZE, RAMP_SECS, RUNTIME_SECS, IDLE_SECS
#   Prereq: SPDK/kernel target up; stream5 connected to .96 group, stream6 to .95.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

LABEL="${1:?usage: ./measure-2host.sh <label> <fiofile>   e.g. ./measure-2host.sh 15 workload-spdk-15.fio}"
FIO="${2:?fiofile}"
[[ -f "$FIO" ]] || { echo "!! fio file '$FIO' not found"; exit 1; }

STREAM6="${STREAM6:-stream6.snu.ac.kr}"
STREAM6_DIR="${STREAM6_DIR:-/home/$(whoami)/zcio-ae-7b-init}"
SSHOPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5"
SSH6="ssh $SSHOPTS $STREAM6"
S5_IP="${S5_IP:-10.3.96.5}"   # stream5 data NIC (96)
S6_IP="${S6_IP:-10.3.95.2}"   # stream6 data NIC (95)
OUT="results-manual"
mkdir -p "$OUT"

# re-stage measure-host.sh + the fio file to stream6 so it matches local edits
$SSH6 "mkdir -p $STREAM6_DIR" || { echo "!! cannot reach $STREAM6 (ssh/dir)"; exit 1; }
tar czf - measure-host.sh "$FIO" | $SSH6 "tar xzf - -C $STREAM6_DIR && chmod +x $STREAM6_DIR/*.sh 2>/dev/null; true"

echo ">>> [2host] label=$LABEL  fio=$FIO   (fresh-SLC + fio on stream5/.96 + stream6/.95, concurrent)"
# pass the env knobs through to both
ENVK="WSET_SIZE=${WSET_SIZE:-} RAMP_SECS=${RAMP_SECS:-} RUNTIME_SECS=${RUNTIME_SECS:-} IDLE_SECS=${IDLE_SECS:-}"
$SSH6 "cd $STREAM6_DIR && sudo -n env $ENVK ./measure-host.sh $OUT $LABEL $FIO $S6_IP" & p6=$!
sudo -n env $ENVK ./measure-host.sh "$OUT" "$LABEL" "$FIO" "$S5_IP" & p5=$!
wait "$p5" || echo "  !! stream5 measure-host nonzero"
wait "$p6" || echo "  !! stream6 measure-host nonzero"

g5=0 c5=0 m5=0 i5=0 l5=0; g6=0 c6=0 m6=0 i6=0 l6=0
[[ -f "$OUT/$LABEL.result" ]] && read -r g5 c5 m5 i5 l5 < "$OUT/$LABEL.result" || echo "  !! stream5 result missing"
r6="$($SSH6 cat "$STREAM6_DIR/$OUT/$LABEL.result" 2>/dev/null)"
[[ -n "$r6" ]] && read -r g6 c6 m6 i6 l6 <<< "$r6" || echo "  !! stream6 result missing"

echo "------------------------------------------------------------"
awk -v g5="$g5" -v g6="$g6" -v m5="$m5" -v m6="$m6" -v i5="$i5" -v i6="$i6" -v l5="$l5" -v l6="$l6" 'BEGIN{
  printf "  stream5(.96): %6.2f GB/s  (%7.0f MiB/s, %6.1f kIOPS, clat %.1f us)\n", g5,m5,i5,l5;
  printf "  stream6(.95): %6.2f GB/s  (%7.0f MiB/s, %6.1f kIOPS, clat %.1f us)\n", g6,m6,i6,l6;
  printf "  TOTAL       : %6.2f GB/s  (%7.0f MiB/s, %6.1f kIOPS)\n", g5+g6, m5+m6, i5+i6 }'
