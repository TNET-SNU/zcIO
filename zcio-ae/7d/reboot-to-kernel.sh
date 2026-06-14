#!/usr/bin/env bash
#
# reboot-to-kernel.sh (stream5)
#   Pick a kernel from the GRUB menu and reboot into it.
#
#   Interactive:  sudo reboot-to-kernel.sh
#   Direct/SSH:   sudo reboot-to-kernel.sh <KERNEL>
#
#   <KERNEL> is a substring matched against the GRUB kernel entries, e.g.
#       5.15.189    -> Ubuntu, with Linux 5.15.189-pduwin      (write-path initiator)
#       6.11        -> Ubuntu, with Linux 6.11.0-hostzc+       (read-path zero-copy)
#       181         -> Ubuntu, with Linux 5.15.0-181-generic
#   It must match exactly ONE entry (ambiguous/no match -> error, no reboot).
#
#   For the write figures (7a/7b) stream5 must run the 5.15.189-pduwin kernel:
#       sudo ./reboot-to-kernel.sh 5.15.189
#
#   By default the choice applies to the NEXT BOOT ONLY (grub-reboot); the
#   system reverts to the persistent default afterwards. Use --permanent to
#   make it the persistent default instead.
set -euo pipefail

GRUB_CFG=/boot/grub/grub.cfg
SUBMENU="Advanced options for Ubuntu"
PERMANENT=0
NOREBOOT=0
ASSUME_YES=0
LIST_ONLY=0
KERNEL=""

usage() {
    cat <<EOF
Usage: sudo $0 [options] [KERNEL]

  KERNEL          substring matching exactly one GRUB kernel entry
                  (e.g. 5.15.189, 6.11, 181). Omit for interactive menu.

Options:
  --permanent     set choice as persistent default (default: next boot only)
  --no-reboot     set the boot target but do not reboot
  --list          list available kernels and exit
  -y, --yes       skip confirmation prompt (implied when KERNEL is given)
  -h, --help      show this help
EOF
}

for arg in "$@"; do
    case "$arg" in
        --permanent) PERMANENT=1 ;;
        --no-reboot) NOREBOOT=1 ;;
        --list)      LIST_ONLY=1 ;;
        -y|--yes)    ASSUME_YES=1 ;;
        -h|--help)   usage; exit 0 ;;
        -*)          echo "Unknown option: $arg" >&2; usage; exit 1 ;;
        *)
            if [[ -n "$KERNEL" ]]; then
                echo "ERROR: multiple KERNEL arguments given ('$KERNEL', '$arg')." >&2
                exit 1
            fi
            KERNEL="$arg" ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root (use sudo)." >&2
    exit 1
fi

# Collect non-recovery kernel entries from the GRUB config.
mapfile -t ENTRIES < <(grep -E "^\s+menuentry '" "$GRUB_CFG" \
    | sed -E "s/^\s+menuentry '([^']*)'.*/\1/" \
    | grep -v "recovery mode")

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
    echo "ERROR: no kernel menuentries found in $GRUB_CFG" >&2
    exit 1
fi

list_kernels() {
    echo "Available kernels:"
    for i in "${!ENTRIES[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "${ENTRIES[$i]}"
    done
}

if [[ $LIST_ONLY -eq 1 ]]; then
    list_kernels
    exit 0
fi

TARGET=""
if [[ -n "$KERNEL" ]]; then
    # Non-interactive: substring-match KERNEL against entries.
    MATCHES=()
    for e in "${ENTRIES[@]}"; do
        if [[ "$e" == *"$KERNEL"* ]]; then
            MATCHES+=("$e")
        fi
    done
    # A substring like "pduwin" also matches GRUB's ".old" fallback duplicate
    # ("5.15.189-pduwin" vs "5.15.189-pduwin.old"), and no substring can tell the
    # primary from its .old suffix. If dropping the ".old" entries leaves exactly
    # one, take it (the current/primary kernel, which is what we want).
    if [[ ${#MATCHES[@]} -gt 1 ]]; then
        NONOLD=()
        for e in "${MATCHES[@]}"; do [[ "$e" == *.old* ]] || NONOLD+=("$e"); done
        [[ ${#NONOLD[@]} -eq 1 ]] && MATCHES=("${NONOLD[@]}")
    fi
    if [[ ${#MATCHES[@]} -eq 0 ]]; then
        echo "ERROR: no kernel entry matches '$KERNEL'." >&2
        list_kernels >&2
        exit 1
    elif [[ ${#MATCHES[@]} -gt 1 ]]; then
        echo "ERROR: '$KERNEL' is ambiguous, matches ${#MATCHES[@]} entries:" >&2
        printf '  %s\n' "${MATCHES[@]}" >&2
        exit 1
    fi
    TARGET="${MATCHES[0]}"
    ASSUME_YES=1   # explicit kernel arg => no prompt (SSH automation)
else
    # Interactive menu.
    list_kernels
    echo
    read -rp "Select kernel to boot [1-${#ENTRIES[@]}]: " CHOICE
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#ENTRIES[@]} )); then
        echo "Invalid selection." >&2
        exit 1
    fi
    TARGET="${ENTRIES[$((CHOICE-1))]}"
fi

ENTRY_PATH="$SUBMENU>$TARGET"

if [[ $PERMANENT -eq 1 ]]; then
    echo "==> Setting PERSISTENT default: $TARGET"
    grub-set-default "$ENTRY_PATH"
else
    echo "==> Setting NEXT-BOOT-ONLY target: $TARGET"
    grub-reboot "$ENTRY_PATH"
fi

if [[ $NOREBOOT -eq 1 ]]; then
    echo "Boot target set. Reboot skipped (--no-reboot)."
    exit 0
fi

if [[ $ASSUME_YES -ne 1 ]]; then
    echo
    read -rp "Reboot now into '$TARGET'? [y/N]: " YN
    case "$YN" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Aborted. Target is set; run 'sudo systemctl reboot' when ready."; exit 0 ;;
    esac
fi

echo "Rebooting into '$TARGET'..."
systemctl reboot
