#!/bin/bash
# bmc-reset.sh — power-cycle a stuck machine over IPMI/BMC (lab recovery).
# Credentials are NOT hardcoded: set them in the environment before running, e.g.
#   BMC_HOST=147.46.219.112 BMC_USER=admin BMC_PASS=****** ./bmc-reset.sh
# (BMC_PASS is prompted for if unset.) See the top-level README recovery section.
set -euo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
if [[ $EUID -ne 0 ]]; then exec sudo -E "$SCRIPT_PATH" "$@"; fi

BMC_HOST="${BMC_HOST:?set BMC_HOST to the BMC IP of the machine to reset}"
BMC_USER="${BMC_USER:-admin}"
if [[ -z "${BMC_PASS:-}" ]]; then read -rsp "BMC password for ${BMC_USER}@${BMC_HOST}: " BMC_PASS; echo; fi

ipmitool -I lanplus -H "$BMC_HOST" -U "$BMC_USER" -P "$BMC_PASS" power cycle
