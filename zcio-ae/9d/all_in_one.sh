#!/bin/bash
# =============================================================================
# all_in_one.sh — one-shot driver for the nginx-over-NVMe/TCP zero-copy
# experiment. Run on the HOST (stream5). Orchestrates target (rapids0) and
# client (creek1) over SSH.
#
#   for CONFIG in linux zcIO:
#       prep target  (rapids0): reset nvmet -> cpu/buffer/rings -> nvmet -> pdu
#       prep host    (stream5): buffer/cpu/rings/gro -> zcopy toggle -> connect
#       for SIZE in 512k 1M 100M:
#           setup nginx (size) -> pin IRQs -> client runs wrk -> record GB/s
#           teardown nginx
#       host: nvme disconnect-all
#   print summary table  ->  results/summary.csv   (plot with: python3 plot.py)
#
# Requires: passwordless SSH host->{target,client} and NOPASSWD sudo on all 3
# (run ./deploy.sh once). A draft for SIGCOMM AE — see README.md.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE"
source "$HERE/config.sh"
source "$HERE/lib.sh"

RES="$HERE/$RESULTS_DIR"
mkdir -p "$RES"
SUMMARY="$RES/summary.csv"
echo "config,size,total_GBps,total_rps" > "$SUMMARY"

# ----- preflight: NOPASSWD sudo on all 3 hosts (run ../deploy.sh first) -------
preflight() {
  log "preflight: NOPASSWD sudo + SSH"
  sudo -n true 2>/dev/null \
    || die "host NOPASSWD sudo missing — run ../deploy.sh first"
  ssh_target sudo -n true 2>/dev/null \
    || die "target $TARGET_HOST NOPASSWD/SSH missing — run ../deploy.sh first"
  ssh_client sudo -n true 2>/dev/null \
    || die "client $CLIENT_HOST NOPASSWD/SSH missing — run ../deploy.sh first"
  sub "all 3 hosts: passwordless sudo OK"
}

# ----- kernel gate: this is a READ experiment, so both hosts MUST be on the
# read-path kernels (host=hostzc, target=pduwin). On the wrong kernel the host
# has no enable_zerocopy and the target enumerates the SSDs differently
# (nvme6n1 -> nvme6n2), which is exactly the "Block device not found" failure.
# We only CHECK here and refuse to proceed; switching reboots both machines.
require_read_kernel() {
  log "kernel gate: require READ kernels (host=$KERN_HOST_READ, target=$KERN_TARGET_READ)"
  local sk rk
  sk="$(uname -r)"
  rk="$(ssh_target uname -r 2>/dev/null)" || die "cannot ssh $TARGET_HOST"
  sub "host    : have '$sk'  need '$KERN_HOST_READ'"
  sub "target  : have '$rk'  need '$KERN_TARGET_READ'"
  if [ "$sk" != "$KERN_HOST_READ" ] || [ "$rk" != "$KERN_TARGET_READ" ]; then
    warn "NOT on the read kernels (this is a write/other environment)."
    warn "switch both machines, wait for them to come back, then re-run this:"
    warn "    ./kernel-switch.sh read --reboot"
    die  "kernel gate failed."
  fi
  sub "both hosts on READ kernels OK"
}

# ----- clean slate: full teardown + restore BEFORE starting (fig-7c style),
# so every run begins from a known-clean state regardless of how the last one
# ended (crash, Ctrl-C, leftover mounts / nvmet config / connections).
clean_slate() {
  log "clean slate: teardown host + target, restore, start clean"
  # host: nginx down, unmount, disconnect, irqbalance restored (teardown.sh)
  sudo killall nginx 2>/dev/null || true
  sudo bash "$HERE/teardown.sh" >/dev/null 2>&1 || true
  sudo nvme disconnect-all 2>/dev/null || true
  # WAIT for the NVMe/TCP controllers to actually disappear. disconnect-all is async;
  # a leftover controller from the PREVIOUS figure (e.g. 9c) is the root cause of
  # "9d after 9c is ~0 GB/s on the first run" — 9d's first connect/mount then races
  # the stale teardown and nginx serves a bad backend. A full cycle (failed run's
  # exit cleanup) clears it, which is why a re-run works. Block here instead.
  local i c left
  for i in $(seq 1 20); do
    left=0
    for c in /sys/class/nvme/nvme*; do
      [ -e "$c/transport" ] || continue
      [ "$(cat "$c/transport" 2>/dev/null)" = tcp ] && left=1
    done
    [ "$left" = 0 ] && break
    sleep 1
  done
  [ "$left" = 0 ] && sub "host: no stale NVMe/TCP controllers" || warn "host: NVMe/TCP controllers still present after 20s"

  # host: make sure the data mounts are actually gone
  local m
  for m in /mnt/rocksdb_test/testdb*; do
    [ -d "$m" ] || continue
    mountpoint -q "$m" 2>/dev/null && { sudo umount -l "$m" 2>/dev/null || true; }
  done

  # target: drop the nvmet config and VERIFY it is actually gone (ports + subsystems
  # empty) before we proceed — not just a fixed sleep.
  ssh_target "sudo bash $TARGET_SCRIPT_DIR/nvmet-9100-teardown.sh" >/dev/null 2>&1 || true
  for i in $(seq 1 20); do
    ssh_target 'ls /sys/kernel/config/nvmet/ports/ 2>/dev/null | grep -q . \
             || ls /sys/kernel/config/nvmet/subsystems/ 2>/dev/null | grep -q .' || break
    sleep 1
  done
  if ssh_target 'ls /sys/kernel/config/nvmet/ports/ 2>/dev/null | grep -q . \
              || ls /sys/kernel/config/nvmet/subsystems/ 2>/dev/null | grep -q .'; then
    warn "target: nvmet ports/subsystems STILL present after 20s"
  else
    sub "target: nvmet fully torn down"
  fi
  sleep "${CLEAN_SETTLE:-5}"
  sub "clean — everything confirmed down."
}

# ----- cleanup on exit (success OR failure): teardown host + target, restore --
cleanup() {
  local rc=$?
  echo
  log "cleanup (exit=$rc): teardown host + target, restore"
  sudo killall nginx 2>/dev/null || true
  sudo bash "$HERE/teardown.sh" >/dev/null 2>&1 || true     # also restarts irqbalance
  sudo nvme disconnect-all 2>/dev/null || true
  ssh_target "sudo bash $TARGET_SCRIPT_DIR/nvmet-9100-teardown.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ----- stage per-host setup scripts (self-contained; no per-figure deploy) ----
# Push this figure's bundled scripts to the machines that need them, using the
# remote user's own permissions (stage_to). Run ONCE before the sweep. The
# environment-wide SSH/sudo setup is done separately by ../deploy.sh (one-time).
stage_setup() {
  log "staging per-host setup scripts"
  stage_to "$TARGET_HOST" "$HERE/rapids0" "$TARGET_SCRIPT_DIR" \
    && sub "target $TARGET_HOST: $TARGET_SCRIPT_DIR" || warn "target staging failed"
  stage_to "$CLIENT_HOST" "$HERE/creek1"  "$CLIENT_SCRIPT_DIR" \
    && sub "client $CLIENT_HOST: $CLIENT_SCRIPT_DIR" || warn "client staging failed"
}

# ----------------------------------------------------------------------------
prep_client_once() {
  log "[client $CLIENT_HOST] prep (net/buffer/cpu via $CLIENT_SCRIPT_DIR)"
  # creek1 env scripts (each self-sudos internally):
  #   init.sh       -> $CLIENT_IFACE @ $CLIENT_NIC_IP, MTU 9000, rings rx/tx 8192
  #   buffer.sh     -> 64MiB socket buffers
  #   cpu_power.sh  -> scaling governor = performance
  ssh_client "C=$CLIENT_SCRIPT_DIR
              bash \$C/init.sh      >/dev/null 2>&1 || true
              bash \$C/buffer.sh    >/dev/null 2>&1 || true
              bash \$C/cpu_power.sh >/dev/null 2>&1 || true
              sudo ethtool -K $CLIENT_IFACE lro on gro on || true
              ping -c1 -W2 $HOST_NIC_IP >/dev/null && echo '    host reachable' || echo '    WARN host unreachable'" \
    || warn "client prep had errors (continuing)"
  # stage the parametrized wrk runner (artifact-authoritative copy)
  ssh_client "mkdir -p $CLIENT_DIR" 2>/dev/null || true
  scp -q $SSH_OPTS "$HERE/remote/run-wrk.sh" "$CLIENT_HOST:$CLIENT_DIR/ae-run-wrk.sh" \
    && ssh_client "chmod +x $CLIENT_DIR/ae-run-wrk.sh" \
    || warn "failed to stage run-wrk.sh on client"
}

prep_target() {
  local zc="$1" pdu
  [ "$zc" = zcIO ] && pdu="$PDU_ALIGN_ON" || pdu="$PDU_ALIGN_OFF"
  log "[target $TARGET_HOST] prep (config=$zc, pdu_align=$pdu)"
  # D = target script dir (rapids0). Order matters:
  #   teardown nvmet -> cores online -> governor -> socket buffers ->
  #   target-net-config (brings ens17np0 UP @10.3.95.10 + MTU/TSO/GSO + rings +
  #   nvme_pdu_align=$pdu) -> nvmet-9100 (creates the TCP listeners on the now-up
  #   NIC). The net-config MUST run before nvmet so the listener binds to a live
  #   interface with its IP — otherwise the initiator's connect times out.
  ssh_target "set -e
    D=$TARGET_SCRIPT_DIR
    sudo bash \$D/nvmet-9100-teardown.sh >/dev/null 2>&1 || true
    sudo bash \$D/cpu_on.sh >/dev/null 2>&1 || true
    sudo bash \$D/cpu-governor.sh performance >/dev/null 2>&1 || true
    sudo bash \$D/buffer.sh >/dev/null 2>&1 || true
    sudo bash \$D/target-net-config.sh $TARGET_MTU $TARGET_TSO $TARGET_GSO $pdu
    sudo bash \$D/nvmet-9100.sh --transport tcp" \
    || die "target prep failed"
}

prep_host() {
  local zc="$1"
  log "[host] prep (config=$zc)"
  # ensure the host has all cores online. nginx is pinned to a single core on
  # purpose, but the host system itself needs its full core count; a prior figure
  # may have left cores offline, which would silently degrade throughput.
  off="$(cat /sys/devices/system/cpu/offline 2>/dev/null)"
  if [ -n "$off" ]; then
    sub "onlining offline host cores ($off)"
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
      id="${c##*/cpu}"; [ "$id" = 0 ] && continue
      [ -e "$c/online" ] && echo 1 | sudo tee "$c/online" >/dev/null
    done
  fi
  sub "host online cores: $(nproc)"
  # data-plane network FIRST: stream5-net.sh reloads mlx5 and brings ens2np0 UP
  # @10.3.95.5/24 (MTU 9000, NIC rings, rx-gro-hw on) so the host can actually
  # reach the target @10.3.95.10 — without this the nvme connect below times out.
  bash "$HERE/stream5-net.sh"        || warn "stream5-net had errors (continuing)"
  bash "$HERE/buffer.sh" >/dev/null  2>&1 || true   # 64MiB socket buffers (self-sudo)
  sudo bash "$HERE/cpu-governor.sh" performance >/dev/null 2>&1 \
    || warn "host cpu-governor performance failed (continuing)"   # match target/client
  sub "host governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
  if [ "$zc" = zcIO ]; then
    sub "zerocopy ON";  bash "$HERE/zcopy_on.sh"  >/dev/null
    bash "$HERE/require-hwgro.sh"     || die "zcIO requires rx-gro-hw on both NICs"
  else
    sub "zerocopy OFF"; bash "$HERE/zcopy_off.sh" >/dev/null
  fi
  sub "enable_zerocopy=$(cat /sys/module/nvme_tcp/parameters/enable_zerocopy 2>/dev/null)"

  log "[host] nvme connect ($NVME_ADDR)"
  sudo modprobe nvme_tcp 2>/dev/null || true
  sudo nvme disconnect-all 2>/dev/null || true   # clear stale paths from a prior run
  sleep 1
  local nqn ok i
  for nqn in "${NVME_NQNS[@]}"; do
    ok=0
    for i in 1 2 3 4 5; do   # connects can time out under burst (zcio-ae pattern)
      sudo nvme connect -t tcp -a "$NVME_ADDR" -s "$NVME_PORT" -n "$nqn" --disable-sqflow && { ok=1; break; }
      sub "retry $i/5: connect $nqn"
      sudo nvme disconnect -n "$nqn" >/dev/null 2>&1 || true
      sleep 2
    done
    [ "$ok" = 1 ] || warn "connect $nqn failed after retries"
  done
  # wait for 4 devices to materialize
  local i n
  for i in $(seq 1 20); do
    n=$(detect_nvme_devs "$NVME_ADDR" | wc -l)
    [ "$n" -ge 4 ] && break
    sleep 1
  done
  sub "connected devices: $(detect_nvme_devs "$NVME_ADDR" | tr '\n' ' ')"
  [ "$n" -ge 4 ] || die "only $n/4 NVMe devices after connect"
}

host_disconnect() {
  log "[host] nvme disconnect-all"
  sudo killall nginx 2>/dev/null
  sudo bash "$HERE/teardown.sh" >/dev/null 2>&1 || true
  sudo nvme disconnect-all 2>/dev/null || true
  sleep 2
}

# verify NIC IRQs are pinned to $HOST_IRQ_CORES and irqbalance is OFF. The single
# biggest reason all_in_one underperformed a hand-run was irqbalance being left ON,
# which re-scatters the ens2np0 IRQs onto the nginx core ($NGINX_CORE) mid-wrk and
# steals cycles from the single-core nginx. Prints a one-line state into the run log
# and warns loudly if the pin did not stick.
verify_irq_pin() {
  local ib bus irq a n=0 bad=0
  ib="$(systemctl is-active irqbalance 2>/dev/null)"
  bus="$(ethtool -i "$HOST_IFACE" 2>/dev/null | awk '/bus-info/{print $2}')"
  for irq in $(grep "$bus" /proc/interrupts 2>/dev/null | awk -F: '{print $1}'); do
    irq="${irq// /}"
    a="$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null)"
    n=$((n+1)); [ "$a" = "$HOST_IRQ_CORES" ] || bad=$((bad+1))
  done
  sub "irq-pin: irqbalance=$ib  NIC IRQs=$n  off-target=$bad  (nginx core=$NGINX_CORE)"
  [ "$ib" = active ] && warn "irqbalance ACTIVE — it will re-scatter NIC IRQs onto core $NGINX_CORE (throughput drop!)"
  [ "$bad" -gt 0 ]   && warn "$bad/$n NIC IRQ(s) NOT on $HOST_IRQ_CORES — perf risk"
}

run_one() {
  local zc="$1" size="$2"
  local t="${WRK_THREADS[$size]}" c="${WRK_CONNS[$size]}"
  local odir="$RES/$zc"; mkdir -p "$odir"

  log "[run] config=$zc size=$size  (wrk t=$t c=$c d=$WRK_DURATION)"
  bash "$HERE/setup-nginx.sh" "$size" || { warn "setup-nginx failed; skipping"; return 1; }
  # Pin NIC IRQs LAST, right before the load (mirrors the well-performing hand-run).
  # set_irq.sh stops irqbalance and pins every ens2np0 IRQ to $HOST_IRQ_CORES. NOT
  # silenced — we must see "Assigned N interrupts" and catch failures. The extra
  # explicit stop is belt-and-suspenders so irqbalance stays OFF through wrk (a live
  # irqbalance re-scatters NIC IRQs onto the nginx core and tanks throughput).
  sudo systemctl stop irqbalance 2>/dev/null || true
  sudo bash "$HERE/set_irq.sh" "$HOST_IFACE" "$HOST_IRQ_CORES" || warn "set_irq failed"
  verify_irq_pin

  local out="$odir/$size.log"
  # Retry the wrk load if it comes back near-0 GB/s: the FIRST config (linux) often
  # gets a cold-start dud — nginx/NVMe-TCP not warmed when wrk hits — that re-runs
  # fine. Accept only when throughput >= MIN_GBPS; otherwise settle + re-run.
  local MIN_GBPS="${MIN_GBPS:-1}"            # below this (GB/s) = treat as cold-start dud
  local MAX_WRK_RETRY="${MAX_WRK_RETRY:-3}"  # total attempts
  local WRK_RETRY_SETTLE="${WRK_RETRY_SETTLE:-5}"
  local gb rps try=1
  while :; do
    ssh_client "WRK_BIN=$WRK_BIN bash $CLIENT_DIR/ae-run-wrk.sh $HOST_NIC_IP $t $c $WRK_DURATION $WRK_TIMEOUT $WRK_WARMUP" \
        2>&1 | tee "$out"
    gb=$(grep -oP 'TOTAL_GBPS=\K[\d.]+' "$out" | tail -1)
    rps=$(grep -oP 'TOTAL_RPS=\K[\d.]+' "$out" | tail -1)
    if [ -n "$gb" ] && awk -v g="$gb" -v m="$MIN_GBPS" 'BEGIN{exit !(g+0 >= m+0)}'; then
      break                                  # good measurement
    fi
    if [ "$try" -ge "$MAX_WRK_RETRY" ]; then
      warn "config=$zc size=$size: ${gb:-NA} GB/s still < ${MIN_GBPS} after ${MAX_WRK_RETRY} tries — recording as-is"
      break
    fi
    warn "config=$zc size=$size: ${gb:-NA} GB/s < ${MIN_GBPS} (cold start?) — retry $((try+1))/${MAX_WRK_RETRY} after ${WRK_RETRY_SETTLE}s"
    sleep "$WRK_RETRY_SETTLE"
    try=$((try+1))
  done
  # show GB/s to 1 decimal (round at the 2nd); leave NA untouched
  [ -n "$gb" ] && gb=$(printf '%.1f' "$gb")
  echo "$zc,$size,${gb:-NA},${rps:-NA}" >> "$SUMMARY"
  sub "=> config=$zc size=$size : ${gb:-NA} GB/s  (try $try/${MAX_WRK_RETRY})"

  sudo bash "$HERE/nginx-teardown.sh" >/dev/null 2>&1 || true
}

# ============================== main ========================================
log "nginx-over-NVMe/TCP zero-copy experiment  (host=$(hostname))"
sub "configs  : ${ZC_MODES[*]}"
sub "sizes    : ${SIZES[*]}"
sub "results  : $RES"

preflight
require_read_kernel
stage_setup
clean_slate
prep_client_once

for zc in "${ZC_MODES[@]}"; do
  echo
  echo "############################################################"
  echo "# CONFIG = $zc"
  echo "############################################################"
  prep_target "$zc"
  prep_host   "$zc"
  for size in "${SIZES[@]}"; do
    run_one "$zc" "$size"
  done
  host_disconnect
done

echo
echo "############################################################"
echo "# SUMMARY (total HTTP throughput, GB/s)"
echo "############################################################"
column -t -s, "$SUMMARY"
echo
sub "raw logs: $RES/<linux|zcIO>/<size>.log"
sub "csv     : $SUMMARY"
sub "plot    : python3 plot.py"

# ----- final teardown: ALL configs/sizes done -> clean everything ONCE --------
# host (nginx/mounts/connections) + target nvmet. Runs only here, after the whole
# sweep, so the environment stays up between sizes/configs during the run itself.
log "final teardown: host + target nvmet"
sudo killall nginx 2>/dev/null || true
sudo bash "$HERE/teardown.sh" >/dev/null 2>&1 || true
sudo nvme disconnect-all 2>/dev/null || true
ssh_target "sudo bash $TARGET_SCRIPT_DIR/nvmet-9100-teardown.sh" >/dev/null 2>&1 || true
sub "all clean (host + target nvmet)."

echo "[all_in_one] done."
