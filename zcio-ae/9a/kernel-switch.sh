#!/bin/bash
# kernel-switch.sh — ensure stream5 + rapids0 are on the right kernels for a
# given direction (read vs write), or switch them there with a reboot.
#
#   ./kernel-switch.sh <read|write>            # CHECK only: verify current kernels,
#                                              #   print status, exit 1 on mismatch
#                                              #   (callers stop and do NOT proceed)
#   ./kernel-switch.sh <read|write> --reboot   # SWITCH: reboot rapids0 + stream5 into
#                                              #   the required kernels (ends this session)
#
# The SENDER always runs the pduwin kernel (has net.ipv4.nvme_pdu_align); the
# RECEIVER runs its zero-copy kernel:
#   read  : stream5=6.11.0-hostzc+           rapids0=5.15.189-pduwin
#           (target sends read data -> pdu on rapids0 ; initiator receives -> zc on stream5)
#   write : stream5=5.15.189-pduwin          rapids0=6.11.0-target-zc-add-frozen+
#           (initiator sends write data -> pdu on stream5 ; target receives -> zc on rapids0)
#
# Kernel names + GRUB-match substrings are overridable via env (KERN_S5_READ, etc).
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
RAPIDS0="${RAPIDS0:-rapids0.snu.ac.kr}"
SSH="ssh -o ConnectTimeout=10 $RAPIDS0"

MODE="${1:-}"; ACTION="${2:-check}"
case "$MODE" in read|write) ;; *) echo "usage: $0 <read|write> [--reboot]"; exit 2 ;; esac

if [[ "$MODE" == read ]]; then
  S5_KERN="${KERN_S5_READ:-6.11.0-hostzc+}";                S5_MATCH="${S5_MATCH:-hostzc}"
  R0_KERN="${KERN_R0_READ:-5.15.189-pduwin}";               R0_MATCH="${R0_MATCH:-pduwin}"
else
  S5_KERN="${KERN_S5_WRITE:-5.15.189-pduwin}";              S5_MATCH="${S5_MATCH:-pduwin}"
  R0_KERN="${KERN_R0_WRITE:-6.11.0-target-zc-add-frozen+}"; R0_MATCH="${R0_MATCH:-target-zc}"
fi

sk="$(uname -r)"
rk="$($SSH uname -r 2>/dev/null)" || { echo "!! cannot ssh $RAPIDS0"; exit 1; }
s5_ok=0; r0_ok=0
[[ "$sk" == "$S5_KERN" ]] && s5_ok=1
[[ "$rk" == "$R0_KERN" ]] && r0_ok=1

echo "[kernel-switch] mode=$MODE"
echo "  stream5 : have '$sk'  need '$S5_KERN'  $([[ $s5_ok == 1 ]] && echo OK || echo MISMATCH)"
echo "  rapids0 : have '$rk'  need '$R0_KERN'  $([[ $r0_ok == 1 ]] && echo OK || echo MISMATCH)"

if [[ "$s5_ok" == 1 && "$r0_ok" == 1 ]]; then
  echo "[kernel-switch] both hosts on the $MODE kernels."
  exit 0
fi

if [[ "$ACTION" != "--reboot" ]]; then
  echo "!! kernel(s) not in '$MODE' configuration — NOT proceeding."
  echo "   switch with:  ./kernel-switch.sh $MODE --reboot"
  exit 1
fi

# ---- perform the switch (reboots) ----
if [[ "$r0_ok" != 1 ]]; then
  echo ">> rebooting rapids0 into '$R0_KERN' (GRUB match '$R0_MATCH') ..."
  ssh -t "$RAPIDS0" "sudo /opt/reboot-to-kernel.sh '$R0_MATCH'" \
    || echo "   (ssh connection dropped — expected once rapids0 starts rebooting)"
fi
if [[ "$s5_ok" != 1 ]]; then
  echo ">> switching stream5 to '$S5_KERN' (GRUB match '$S5_MATCH') and rebooting NOW ..."
  echo "   (this ends the session; after both hosts are back, re-run ./all-in-one.sh)"
  sudo ./reboot-to-kernel.sh "$S5_MATCH"     # reboots stream5; session ends here
else
  echo ">> stream5 already on '$S5_KERN'. After rapids0 is back up, re-run ./all-in-one.sh"
fi
