#!/bin/bash
# mount_4disk.sh — mkfs + mount the 4 NVMe/TCP target drives on /mnt/rocksdb_test.
#
# Devices are DISCOVERED, not hardcoded. fig-9a now exports all 4 drives as 4
# namespaces under ONE subsystem, so on the initiator they show up as
# /dev/nvme0n1 /dev/nvme0n2 /dev/nvme0n3 /dev/nvme0n4 (one controller). Older
# per-drive layouts show up as nvme0n1 nvme1n1 nvme2n1 nvme3n1. Either way we
# just enumerate the NVMe/TCP namespace head devices, sort them, and take 4.
set -uo pipefail

# Collect unique head devices behind tcp controllers (multipath path nvmeXcYnZ
# -> head nvmeXnZ). Mirrors fig-9a connect.sh's count_heads logic.
declare -A seen
DEVS=()
for c in /sys/class/nvme/nvme*; do
    [[ -r "$c/transport" ]] || continue
    [[ "$(cat "$c/transport" 2>/dev/null)" == tcp ]] || continue
    for ns in "$c"/nvme*n*; do
        [[ -e "$ns" ]] || continue
        head="$(basename "$ns" | sed -E 's/c[0-9]+n/n/')"
        [[ "$head" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
        [[ -b "/dev/$head" ]] || continue
        [[ -n "${seen[$head]:-}" ]] && continue
        seen[$head]=1; DEVS+=("$head")
    done
done

# Sort by controller-then-nsid (nvme0n1, nvme0n2, ...) for stable testdb mapping.
IFS=$'\n' DEVS=($(printf '%s\n' "${DEVS[@]}" | sort -V)); unset IFS

if [[ "${#DEVS[@]}" -lt 4 ]]; then
    echo "ERROR: found ${#DEVS[@]} NVMe/TCP namespace head(s), need 4 — run fig-9a connect first"
    printf '  found: %s\n' "${DEVS[*]:-<none>}"
    exit 1
fi
[[ "${#DEVS[@]}" -gt 4 ]] && echo "WARN: ${#DEVS[@]} tcp heads present; using first 4: ${DEVS[*]:0:4}"
DEVS=("${DEVS[@]:0:4}")
echo "[mount] target namespaces: /dev/${DEVS[0]} /dev/${DEVS[1]} /dev/${DEVS[2]} /dev/${DEVS[3]}"

for i in 1 2 3 4; do sudo mkdir -p "/mnt/rocksdb_test/testdb$i"; done

# Per disk: REUSE if it already holds the UNet3D dataset (mounts cleanly AND has
# files in mlperf_data/unet3d/train) -> skip mkfs, keep the data. Otherwise mkfs
# fresh. The dataset lives on the NVMe/TCP target and persists across
# disconnect/reconnect, so this avoids wiping + regenerating ~500 GB every config.
# Self-correcting: if the data is gone (mount fails or dir empty) it falls back to
# mkfs, so a first/clean run still works. Set FORCE_MKFS=1 to always reformat.
DATA_SUB="mlperf_data/unet3d/train"
for i in 0 1 2 3; do
    n=$((i + 1))
    dev="/dev/${DEVS[$i]}"
    mnt="/mnt/rocksdb_test/testdb$n"
    mountpoint -q "$mnt" && sudo umount "$mnt" 2>/dev/null || true
    if [[ "${FORCE_MKFS:-0}" != 1 ]] \
        && sudo mount "$dev" "$mnt" 2>/dev/null \
        && [ -d "$mnt/$DATA_SUB" ] && [ -n "$(ls -A "$mnt/$DATA_SUB" 2>/dev/null)" ]; then
        echo "[mount] testdb$n: dataset present on $dev -> REUSE (skip mkfs)"
    else
        sudo umount "$mnt" 2>/dev/null || true
        echo "[mount] testdb$n: no dataset on $dev -> mkfs + mount"
        sudo mkfs.ext4 -F -b 4096 "$dev" \
            || { echo "ERROR: mkfs failed on $dev"; exit 1; }
        sudo mount "$dev" "$mnt"
    fi
done

echo "[mount] mounted testdb1..4 on /mnt/rocksdb_test"
