#!/bin/bash
# oneq-test.sh — test OFFLINE-then-CONNECT (1 clean I/O queue/device on cpu0)
# vs the current connect-then-offline. Measures default+zcIO at the live perdisk,
# so we can compare the 64k/128k speedup ratio AND CPU% to the connect-first runs.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
RDIR=/opt/rocksdb-env
for cfg in default zcIO; do
    pdu=0; zc=off; [ "$cfg" = zcIO ] && { pdu=2; zc=on; }
    echo "########## $cfg : offline cpu1+ FIRST, then connect ##########"
    ./disconnect.sh || true
    ./set-cores.sh single
    NET_PDU=$pdu ZCOPY=$zc ./setup.sh >/tmp/oneq-setup-$cfg.log 2>&1 \
        && echo "  setup ok (online cpus=$(nproc))" || { echo "  setup FAILED"; continue; }
    sudo -n "$RDIR/unmount_4disk.sh" >/dev/null 2>&1 || true
    sudo -n "$RDIR/mount_4disk.sh" >/tmp/oneq-mount-$cfg.log 2>&1 || { echo "  mount FAILED"; continue; }
    sudo -n "$RDIR/rocksdb-run.sh" "oneq-$cfg" 32 2 > "/tmp/oneq-run-$cfg.log" 2>&1
    cp "$RDIR/results-rocksdb-oneq-$cfg.csv" . 2>/dev/null || true
    echo "  $cfg done"
done
sudo -n "$RDIR/unmount_4disk.sh" >/dev/null 2>&1 || true
./set-cores.sh all || true
./disconnect.sh || true
echo "ONEQ-TEST DONE"
