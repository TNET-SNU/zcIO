#!/bin/bash
# lib.sh — shared helpers. Source config.sh before this.

SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o BatchMode=yes"
ssh_target() { ssh $SSH_OPTS "$TARGET_HOST" "$@"; }
ssh_client() { ssh $SSH_OPTS "$CLIENT_HOST" "$@"; }

log()  { printf '\n\033[1;36m>>> %s\033[0m\n' "$*"; }
sub()  { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

# Run a command as root on the host. Uses sudo -n (NOPASSWD); if that is not set
# up, falls back to plain sudo (will prompt — fine for interactive runs).
as_root() {
  if sudo -n true 2>/dev/null; then sudo "$@"; else sudo "$@"; fi
}

# Stage a local dir of setup scripts to a remote machine, using the remote login
# user's OWN permissions. The dest lives under that user's home but may hold
# root-owned files from a legacy manual setup, so we take ownership ONCE (sudo
# chown) and then copy with a plain `tar | ssh -> tar` (no root). Idempotent:
# on later runs the dir is already user-owned and the chown is a no-op.
#   stage_to <host> <local_srcdir> <remote_dstdir>
stage_to() {
  local host="$1" srcdir="$2" dstdir="$3"
  [ -d "$srcdir" ] || { warn "stage_to: $srcdir missing"; return 1; }
  ssh $SSH_OPTS "$host" "sudo mkdir -p $dstdir && sudo chown -R \$(id -un):\$(id -gn) $dstdir" \
    || { warn "[$host] could not take ownership of $dstdir"; return 1; }
  tar czf - -C "$srcdir" . \
    | ssh $SSH_OPTS "$host" "tar xzf - -C $dstdir \
        && chmod +x $dstdir/*.sh 2>/dev/null; chmod +x $dstdir/*.py 2>/dev/null; true"
}

# Detect the NVMe HEAD block devices behind the TCP controllers connected to $1
# (target IP; empty = any TCP controller). Prints "/dev/nvmeXn1" lines, sorted &
# de-duplicated. Works without sudo.
#
# IMPORTANT (nvme_core.multipath=Y, which stream5 uses): a connected subsystem
# shows up under /sys/class/nvme/nvmeX as a PATH device named nvmeXcYnZ — that is
# NOT a usable block device. The mountable HEAD is nvmeXnZ. We normalize the path
# name (strip "cY") to the head and keep only real block devices. Borrowed from
# zcio-ae fig-7a count_heads(). Without this, detection silently returns nothing
# (or path names that mkfs can't open) on a multipath kernel.
detect_nvme_devs() {
  local addr="$1" c ns head
  declare -A seen
  for c in /sys/class/nvme/nvme*; do
    [ -e "$c/transport" ] || continue
    [ "$(cat "$c/transport" 2>/dev/null)" = tcp ] || continue
    if [ -n "$addr" ]; then grep -q "$addr" "$c/address" 2>/dev/null || continue; fi
    for ns in "$c"/nvme*n*; do
      [ -e "$ns" ] || continue
      head="$(basename "$ns" | sed -E 's/c[0-9]+n/n/')"   # nvme6c6n1 -> nvme6n1
      [ -b "/dev/$head" ] || continue
      [ -n "${seen[$head]:-}" ] && continue
      seen[$head]=1
      echo "/dev/$head"
    done
  done | sort -u
}

# Wait until an interface is operstate=up (best effort).
wait_iface_up() {
  local ifc="$1" i
  for i in $(seq 1 30); do
    [ "$(cat /sys/class/net/$ifc/operstate 2>/dev/null)" = up ] && return 0
    sleep 1
  done
  return 1
}
