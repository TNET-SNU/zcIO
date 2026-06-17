#!/bin/bash
# teardown.sh — fig-9a: undo setup.sh.
#   [stream5]  disconnect all NVMe/TCP sessions
#   [rapids0]  target-restore.sh (all cores online + mlx5 reload + nvmet reset)
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
RAPIDS0_DIR="${RAPIDS0_DIR:-$HOME/zcio-ae-9c}"
SSH="ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 $RAPIDS0"

echo ">>> [initiator stream5] disconnect all NVMe/TCP sessions"
./disconnect.sh || echo "!! disconnect reported an error (continuing)"

echo ">>> [target rapids0] target-restore.sh (cores online + mlx5 reload + nvmet reset)"
$SSH sudo -n "$RAPIDS0_DIR/target-restore.sh" \
    || echo "!! rapids0 restore reported an error — check it (ssh $RAPIDS0 sudo $RAPIDS0_DIR/target-restore.sh)"

echo "[teardown] done."
