#!/bin/bash
set -euo pipefail
set -x

SCRIPT_PATH="$(readlink -f "$0")"

if [[ $EUID -ne 0 ]]; then
    exec sudo -n "$SCRIPT_PATH" "$@"
fi

# CPU0 는 offline 불가 -> cpu1 이상 전부 offline 시켜 1코어만 남긴다
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    id="${cpu##*/cpu}"
    [[ "$id" == "0" ]] && continue
    [[ -w "$cpu/online" ]] || continue
    echo 0 > "$cpu/online"
done

echo "online CPU: $(nproc)"
grep -H . /sys/devices/system/cpu/online
