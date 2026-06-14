#!/usr/bin/env bash
set -uo pipefail

# ----------------------------------------------------------------------------
# Show / set CPU scaling_governor across all cores.
#
# Usage:
#   ./cpu-governor.sh                    # show current governor (no root)
#   sudo ./cpu-governor.sh performance   # set all cores to performance
#   sudo ./cpu-governor.sh powersave     # or any supported governor
#   sudo ./cpu-governor.sh --show        # show only, even with sudo
# ----------------------------------------------------------------------------

GOV_GLOB="/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
AVAIL_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"
INTEL_PSTATE="/sys/devices/system/cpu/intel_pstate"

show_current() {
  echo "== Current governor per core =="
  for f in ${GOV_GLOB}; do
    [[ -e "$f" ]] || continue
    cpu=$(echo "$f" | grep -oP 'cpu\d+')
    printf "  %-7s %s\n" "${cpu}:" "$(cat "$f")"
  done

  echo
  echo "== Summary =="
  cat ${GOV_GLOB} 2>/dev/null | sort | uniq -c | awk '{printf "  %4d core(s): %s\n", $1, $2}'

  if [[ -e "${AVAIL_FILE}" ]]; then
    echo
    echo "== Available governors =="
    echo "  $(cat "${AVAIL_FILE}")"
  fi

  if [[ -e "${INTEL_PSTATE}/status" ]]; then
    echo
    echo "== intel_pstate =="
    echo "  status:        $(cat ${INTEL_PSTATE}/status)"
    [[ -e "${INTEL_PSTATE}/no_turbo"     ]] && echo "  no_turbo:      $(cat ${INTEL_PSTATE}/no_turbo)"
    [[ -e "${INTEL_PSTATE}/min_perf_pct" ]] && echo "  min_perf_pct:  $(cat ${INTEL_PSTATE}/min_perf_pct)"
    [[ -e "${INTEL_PSTATE}/max_perf_pct" ]] && echo "  max_perf_pct:  $(cat ${INTEL_PSTATE}/max_perf_pct)"
  fi
}

set_governor() {
  local target="$1"

  if [[ "${EUID}" -ne 0 ]]; then
    echo "Setting governor requires root: sudo $0 ${target}"
    exit 1
  fi

  # Validate against available governors (cpu0 is representative)
  if [[ -e "${AVAIL_FILE}" ]]; then
    local avail
    avail="$(cat "${AVAIL_FILE}")"
    if ! grep -qw "${target}" <<< "${avail}"; then
      echo "Governor '${target}' is not supported. Available: ${avail}"
      exit 1
    fi
  fi

  echo "Setting governor=${target} on all cores..."
  local cnt=0 fail=0
  for f in ${GOV_GLOB}; do
    [[ -e "$f" ]] || continue
    if echo "${target}" > "$f" 2>/dev/null; then
      cnt=$((cnt + 1))
    else
      echo "  FAILED: $f"
      fail=$((fail + 1))
    fi
  done
  echo "  ok=${cnt} fail=${fail}"

  # On intel_pstate active mode, also ensure turbo is on and min_perf is high
  # when the user is asking for 'performance' (max throughput intent).
  if [[ "${target}" == "performance" && -e "${INTEL_PSTATE}/status" ]]; then
    if [[ "$(cat ${INTEL_PSTATE}/status)" == "active" ]]; then
      [[ -w "${INTEL_PSTATE}/no_turbo"     ]] && echo 0   > "${INTEL_PSTATE}/no_turbo"
      [[ -w "${INTEL_PSTATE}/min_perf_pct" ]] && echo 100 > "${INTEL_PSTATE}/min_perf_pct"
      echo "  intel_pstate: no_turbo=0, min_perf_pct=100"
    fi
  fi

  echo
  show_current
}

# ---- arg parse ----
MODE="show"
TARGET=""
if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      sed -n '3,12p' "$0"
      exit 0
      ;;
    --show|show)
      MODE="show"
      ;;
    *)
      MODE="set"
      TARGET="$1"
      ;;
  esac
fi

if [[ ! -e "/sys/devices/system/cpu/cpu0/cpufreq" ]]; then
  echo "cpufreq sysfs not present. cpufreq driver loaded?"
  exit 1
fi

case "${MODE}" in
  show) show_current ;;
  set)  set_governor "${TARGET}" ;;
esac
