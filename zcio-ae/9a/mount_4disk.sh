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

# REUSE=1 -> keep the existing filesystem + data (mount only, NO mkfs), so the same
# workload's data can be reused across configs (default -> zcIO) without a costly
# regenerate. Falls back to mkfs if there's no mountable FS. REUSE=0 (default)
# reformats fresh -- used for a new workload's first config.
REUSE="${REUSE:-0}"
for i in 0 1 2 3; do
    n=$((i + 1))
    dev="/dev/${DEVS[$i]}"
    mnt="/mnt/rocksdb_test/testdb$n"
    mountpoint -q "$mnt" && sudo umount "$mnt" 2>/dev/null || true
    if [[ "$REUSE" == 1 ]] && sudo mount "$dev" "$mnt" 2>/dev/null; then
        echo "[mount] testdb$n: REUSE existing FS on $dev (no mkfs)"
    else
        [[ "$REUSE" == 1 ]] && { echo "[mount] testdb$n: REUSE requested but no FS on $dev -> mkfs"; sudo umount "$mnt" 2>/dev/null || true; }
        sudo mkfs.ext4 -F -b 4096 "$dev" \
            || { echo "ERROR: mkfs failed on $dev"; exit 1; }
        sudo mount "$dev" "$mnt"
    fi
done

echo "[mount] mounted testdb1..4 on /mnt/rocksdb_test"
