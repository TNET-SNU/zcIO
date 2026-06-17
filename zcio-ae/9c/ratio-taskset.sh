#!/bin/bash
# ratio-taskset.sh — default vs zcIO in TASKSET single-core mode (all cores
# online, app pinned to cpu0, kernel I/O softirq spread across all cores).
# Measures the full 5-bs table for both configs so we can compare the zcIO/default
# speedup RATIO to the reference.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
RDIR=/opt/rocksdb-env
for cfg in default zcIO; do
    pdu=0; zc=off; [ "$cfg" = zcIO ] && { pdu=2; zc=on; }
    echo "########## $cfg (taskset, cores online) ##########"
    ./disconnect.sh || true
    NET_PDU=$pdu ZCOPY=$zc ./setup.sh >/tmp/ts-${cfg}-setup.log 2>&1 \
        && echo "  setup ok (online=$(nproc))" || { echo "  setup FAILED"; continue; }
    sudo -n "$RDIR/unmount_4disk.sh" >/dev/null 2>&1 || true
    sudo -n "$RDIR/mount_4disk.sh" >/tmp/ts-${cfg}-mount.log 2>&1 || { echo "  mount FAILED"; continue; }
    sudo -n "$RDIR/rocksdb-run.sh" "tsfull-$cfg" 32 2 "" "" taskset > "/tmp/ts-${cfg}-run.log" 2>&1
    cp "$RDIR/results-rocksdb-tsfull-$cfg.csv" . 2>/dev/null || true
    echo "  $cfg done"
done
sudo -n "$RDIR/unmount_4disk.sh" >/dev/null 2>&1 || true
./disconnect.sh || true
echo "=== RATIO (taskset mode) ==="
python3 - <<'PY'
import csv,os
def avgs(label):
    p=f"results-rocksdb-{label}.csv"; out={}
    if not os.path.exists(p): return out
    for r in csv.DictReader(open(p)):
        if r.get("rep")=="avg":
            try: out[r["bs"]]=float(r["ops_per_s"])
            except: pass
    return out
order=["4k","32k","64k","128k","256k"]
REFd={"4k":99036,"32k":45557,"64k":29802.75,"128k":17904,"256k":6416.25}
REFz={"4k":99901,"32k":51412.25,"64k":43077.75,"128k":28213.25,"256k":9923.75}
d=avgs("tsfull-default"); z=avgs("tsfull-zcIO")
print(f"{'bs':<6}{'default':>9}{'zcIO':>9}{'our_ratio':>10}{'ref_ratio':>10}")
for bs in order:
    dv=d.get(bs,0); zv=z.get(bs,0); r=zv/dv if dv else 0
    print(f"{bs:<6}{dv:>9.0f}{zv:>9.0f}{r:>9.2f}x{REFz[bs]/REFd[bs]:>9.2f}x")
PY
echo DONE
