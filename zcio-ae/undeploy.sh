#!/bin/bash
# undeploy.sh — remove the NOPASSWD sudoers installed by deploy.sh on all machines.
set -uo pipefail
REMOTE_HOSTS=(rapids0.snu.ac.kr creek1.snu.ac.kr)
SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes"
SUDOERS="/etc/sudoers.d/zcio-ae"
LEGACY="/etc/sudoers.d/zcio-nginx-ae"
log()  { printf '\n\033[1;36m>>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }

log "[host/stream5] removing sudoers"; sudo rm -f "$SUDOERS" "$LEGACY"
for h in "${REMOTE_HOSTS[@]}"; do
  log "[$h] removing sudoers"
  ssh $SSH_OPTS "$h" "sudo rm -f $SUDOERS $LEGACY" || warn "[$h] failed"
done
log "undeploy done."
