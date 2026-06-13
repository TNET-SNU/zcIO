#!/bin/bash
# =============================================================================
# config.sh — all tunables for the nginx-over-NVMe/TCP zero-copy experiment.
#
# Topology (3 machines):
#   target  (rapids0) : NVMe/TCP target, exports 4x Samsung 9100 PRO over ens17np0
#   host    (stream5) : THIS machine — NVMe/TCP initiator + nginx file server
#   client  (creek1)  : runs 4x parallel wrk against nginx
#
# The experiment sweeps {linux, zcIO} x {file sizes} and reports the total
# HTTP throughput (GB/s) the client sees, so we can compare against the paper.
# Edit values here; every other script sources this file.
# =============================================================================

# ---- machines (SSH targets; host is local, no SSH) --------------------------
TARGET_HOST="${TARGET_HOST:-rapids0.snu.ac.kr}"
CLIENT_HOST="${CLIENT_HOST:-creek1.snu.ac.kr}"

# ---- NICs / IPs -------------------------------------------------------------
TARGET_IFACE="${TARGET_IFACE:-ens17np0}";  TARGET_NIC_IP="${TARGET_NIC_IP:-10.3.95.10}"
HOST_IFACE="${HOST_IFACE:-ens2np0}";       HOST_NIC_IP="${HOST_NIC_IP:-10.3.95.5}"
CLIENT_IFACE="${CLIENT_IFACE:-ens17f0np0}";CLIENT_NIC_IP="${CLIENT_NIC_IP:-10.3.95.134}"

# ---- NVMe/TCP ---------------------------------------------------------------
NVME_ADDR="${NVME_ADDR:-10.3.95.10}"     # target IP the initiator connects to
NVME_PORT="${NVME_PORT:-4420}"
# Subsystem NQNs exported by the target (4 devices behind ens17np0).
NVME_NQNS=(
  nvmet-ens17np0-nvme6n1
  nvmet-ens17np0-nvme7n1
  nvmet-ens17np0-nvme8n1
  nvmet-ens17np0-nvme9n1
)

# ---- per-host script locations ----------------------------------------------
# HOST (stream5) data-plane/zcopy scripts are LOCAL to this artifact dir ($HERE
# in all_in_one.sh). TARGET (rapids0) nvmet + data-plane scripts live in this
# dir on rapids0 and are run over SSH.
TARGET_SCRIPT_DIR="${TARGET_SCRIPT_DIR:-/home/syeon/zcio-ae-9d}"
# CLIENT (creek1) data-plane/cpu setup scripts (init.sh, buffer.sh, cpu_power.sh).
CLIENT_SCRIPT_DIR="${CLIENT_SCRIPT_DIR:-/home/syeon/zcio-ae-9d}"
# target-net-config.sh positional args for the read path: jumbo MTU, TSO on, GSO off.
TARGET_MTU="${TARGET_MTU:-9000}"; TARGET_TSO="${TARGET_TSO:-on}"; TARGET_GSO="${TARGET_GSO:-off}"

# ---- nginx (on host/stream5) ------------------------------------------------
NGINX_BIN="${NGINX_BIN:-/usr/sbin/nginx}"   # stock 1.24.0 (--with-threads → supports `aio threads`); == what `sudo bash setup_server.sh` runs (sudo secure_path excludes /usr/local/nginx/sbin)
NGINX_CORE="${NGINX_CORE:-6}"            # nginx pinned to this core (paper: single core)
HOST_IRQ_CORES="${HOST_IRQ_CORES:-0-5}"  # NIC IRQ affinity on the host
MOUNT_BASE="${MOUNT_BASE:-/mnt/remote}"  # -> /mnt/remote1 .. /mnt/remote4

# ---- client (creek1) --------------------------------------------------------
CLIENT_DIR="${CLIENT_DIR:-/home/syeon/zcio-ae-9d}"
WRK_BIN="${WRK_BIN:-/opt/wrk/wrk}"   # wrk binary on creek1 (deploy.sh installs it here)
WRK_DURATION="${WRK_DURATION:-30s}"
WRK_TIMEOUT="${WRK_TIMEOUT:-10s}"
WRK_WARMUP="${WRK_WARMUP:-5s}"      # warmup before measurement (discarded); 0s = skip

# ---- ethtool ring sizes -----------------------------------------------------
TARGET_RX="${TARGET_RX:-4096}"; TARGET_TX="${TARGET_TX:-8192}"
HOST_RX="${HOST_RX:-4096}";     HOST_TX="${HOST_TX:-8192}"
CLIENT_RX="${CLIENT_RX:-8192}"; CLIENT_TX="${CLIENT_TX:-8192}"

# =============================================================================
# Experiment matrix
# =============================================================================
# zero-copy modes to sweep (script-level toggle; vanilla-kernel A/B is future work)
# Paper naming: "linux" = default kernel path (zero-copy OFF), "zcIO" = receive
# zero-copy ON. (Internally linux->enable_zerocopy=0/pdu_align=0, zcIO->1/2.)
ZC_MODES=(${ZC_MODES:-linux zcIO})

# file sizes to sweep (labels). Bytes + nginx output_buffers per label below.
SIZES=(${SIZES:-512k 1M 100M})

# label -> file size in bytes
declare -A SIZE_BYTES=(
  [512k]=$((512*1024))
  [1M]=$((1024*1024))
  [100M]=$((100*1024*1024))
)

# label -> nginx output_buffers size (== bs that goes down to NVMe).
# 512k file must use 512k; everything else uses 1024k.
declare -A SIZE_OBUF=(
  [512k]=512k
  [1M]=1024k
  [100M]=1024k
)

# ---- wrk tuning per file size (TUNE THESE) ----------------------------------
# Per-wrk-instance threads/connections; 4 instances run in parallel (one per dev).
declare -A WRK_THREADS=(
  [512k]=4
  [1M]=3
  [100M]=2
)
declare -A WRK_CONNS=(
  [512k]=5
  [1M]=4
  [100M]=2
)

# =============================================================================
# nvme_tcp zero-copy module parameters (host) — used by the "zcIO" path.
# Mirrors /home/syeon/zcopy_on.sh.
# =============================================================================
ZC_BATCH_PAGES="${ZC_BATCH_PAGES:-8}"
ZC_BATCH_FLUSH="${ZC_BATCH_FLUSH:-Y}"
ZC_IDLE_US="${ZC_IDLE_US:-200000}"

# target PDU alignment: 0 for linux, 2 for zcIO (net.ipv4.nvme_pdu_align)
PDU_ALIGN_OFF="${PDU_ALIGN_OFF:-0}"
PDU_ALIGN_ON="${PDU_ALIGN_ON:-2}"

# =============================================================================
# Kernel direction (READ path — nginx serves reads from NVMe/TCP).
# The SENDER (target) runs the pduwin kernel (has net.ipv4.nvme_pdu_align);
# the RECEIVER (host) runs the host zero-copy kernel.
#   read : host(stream5)=6.11.0-hostzc+   target(rapids0)=5.15.189-pduwin
# all_in_one.sh refuses to run unless both hosts are on these (kernel-switch.sh).
# =============================================================================
KERN_HOST_READ="${KERN_HOST_READ:-6.11.0-hostzc+}"
KERN_TARGET_READ="${KERN_TARGET_READ:-5.15.189-pduwin}"

# ---- output -----------------------------------------------------------------
RESULTS_DIR="${RESULTS_DIR:-results}"
