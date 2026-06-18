#!/bin/bash
# deploy.sh — ONE-TIME environment setup for the whole AE. Run this ONCE on the
# host (stream5), before any figure. It does NOT need to be re-run per figure.
#   1. verify passwordless SSH from here to the other machines
#   2. install NOPASSWD sudo for $USER on every machine (/etc/sudoers.d/zcio-ae)
# The experiment environment is shared across all figures, so this is one-time.
# Each figure's all_in_one.sh stages its own per-host setup scripts automatically.
set -uo pipefail

# Machines used by the AE. The host (stream5) is local. stream6 is the SECOND
# initiator for the write figures (7a/7b). creek1 is only used by figure 9d (nginx
# client); setting all of them up here is harmless for the other figures.
# NOTE: stream6 has password auth disabled — passwordless SSH needs a key there
# (ssh-copy-id stream6.snu.ac.kr), then this installs its NOPASSWD sudoers.
REMOTE_HOSTS=(rapids0.snu.ac.kr stream6.snu.ac.kr creek1.snu.ac.kr)

SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes"
SUDOERS="/etc/sudoers.d/zcio-ae"
LEGACY="/etc/sudoers.d/zcio-nginx-ae"     # older name; removed if present
USER_NAME="$(whoami)"
RULE="$USER_NAME ALL=(ALL) NOPASSWD: ALL"
log()  { printf '\n\033[1;36m>>> %s\033[0m\n' "$*"; }
sub()  { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

log "[host/stream5] installing NOPASSWD sudoers ($SUDOERS)"
echo "$RULE" | sudo tee "$SUDOERS" >/dev/null && sudo chmod 440 "$SUDOERS"
sudo rm -f "$LEGACY"
sudo visudo -cf "$SUDOERS" && sub "ok" || die "sudoers syntax check failed"

for h in "${REMOTE_HOSTS[@]}"; do
  log "[$h] passwordless SSH + NOPASSWD sudoers"
  ssh $SSH_OPTS "$h" true 2>/dev/null && sub "ssh ok" \
    || { warn "SSH not passwordless — run: ssh-copy-id $h"; continue; }
  ssh -t $SSH_OPTS "$h" "echo '$RULE' | sudo tee $SUDOERS >/dev/null \
      && sudo chmod 440 $SUDOERS && sudo rm -f $LEGACY && sudo visudo -cf $SUDOERS" \
    && sub "sudo ok" || warn "[$h] sudoers install failed (check ssh/sudo)"
done

log "deploy done. Now run any figure with:  cd <figure> && ./all_in_one.sh"
