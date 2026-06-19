#!/usr/bin/env bash
# Set up ownership of the MLPerf UNet3D data directories.
#
# testdb{1,2,3,4} and mlperf_merged are owned by root/ki, so the current user
# cannot create the datagen/symlink files (PermissionError). This script hands
# ownership to the current user.
#
# Usage: ./setup_permissions.sh   (may prompt for the sudo password)
set -e

OWNER="$(id -un)"          # current user
GROUP="$(id -gn)"
BASE="/mnt/rocksdb_test"

echo "ownership target user: ${OWNER}:${GROUP}"

# ── testdb1~4: datagen creates mlperf_data/ here (9a/9b/9c fixed at 4 disks) ──
for i in 1 2 3 4; do
    DISK="${BASE}/testdb${i}"
    if [ ! -d "$DISK" ]; then
        echo "WARNING: ${DISK} not found → skipping"
        continue
    fi
    echo "  chown -R ${OWNER}:${GROUP} ${DISK}"
    sudo chown -R "${OWNER}:${GROUP}" "$DISK"
done

# ── mlperf_merged: symlink merge dir (BASE is owned by ki, so create then hand over) ──
MERGED="${BASE}/mlperf_merged"
echo "  mkdir + chown ${MERGED}"
sudo mkdir -p "$MERGED"
sudo chown -R "${OWNER}:${GROUP}" "$MERGED"

echo ""
echo "── result ──"
ls -ld "${BASE}"/testdb[1-4] "$MERGED" 2>/dev/null || true
echo ""
echo "Done. You can now run ./setup_4disk_simple.sh without sudo."
