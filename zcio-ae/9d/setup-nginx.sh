#!/bin/bash
# setup-nginx.sh <size_label>  — run ON the host (stream5).
# Parametrized rewrite of nginx/setup_server.sh:
#   * auto-detects the 4 NVMe/TCP devices (names vary run-to-run)
#   * FILE_SIZE and nginx output_buffers driven by the size label + config.sh
#   * formats xfs, mounts 4 devices, generates test.mp4, starts nginx on 1 core
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$HERE/config.sh"
source "$HERE/lib.sh"

LABEL="${1:?usage: setup-nginx.sh <size_label e.g. 512k|1M|100M>}"
FILE_SIZE="${SIZE_BYTES[$LABEL]:?unknown size label '$LABEL'}"
OBUF="${SIZE_OBUF[$LABEL]:?no output_buffers for '$LABEL'}"

log "[host] setup-nginx: size=$LABEL bytes=$FILE_SIZE output_buffers=$OBUF"

# ---- detect devices ---------------------------------------------------------
mapfile -t DEVS < <(detect_nvme_devs "$NVME_ADDR")
if [ "${#DEVS[@]}" -lt 4 ]; then
  die "expected 4 NVMe/TCP devices for $NVME_ADDR, found ${#DEVS[@]}: ${DEVS[*]:-none}. Is connect done?"
fi
DEVS=("${DEVS[@]:0:4}")
sub "devices: ${DEVS[*]}"

# ---- format + mount + data --------------------------------------------------
sudo umount /mnt/raid0 2>/dev/null
sudo mdadm --stop /dev/md0 2>/dev/null
for i in 0 1 2 3; do
  MP="${MOUNT_BASE}$((i+1))"
  # Fully clear this mountpoint FIRST. NVMe/TCP reconnects re-enumerate namespaces
  # (nvme0n1 -> n2 -> n3 ...) and a single umount only peels the top layer, so old
  # mounts STACK — nginx then serves from whatever stale namespace ended up on top,
  # and `mkdir -p` on a stale mount (dead backing dev) returns EIO. Lazy-umount in a
  # loop until the point is truly empty, THEN mkdir, so we serve exactly DEVS[$i].
  while mount | grep -q " $MP "; do sudo umount -l "$MP" 2>/dev/null || break; done
  sudo mkdir -p "$MP"
  sub "mkfs.xfs ${DEVS[$i]} -> $MP"
  sudo mkfs.xfs -f -s size=4096 -b size=4096 "${DEVS[$i]}" >/dev/null || die "mkfs failed on ${DEVS[$i]}"
  sudo mount -o noatime,nodiscard "${DEVS[$i]}" "$MP" || die "mount failed on ${DEVS[$i]}"
  sudo mkdir -p "$MP/video"
  sub "generating $MP/video/test.mp4 ($FILE_SIZE bytes)"
  sudo openssl rand -out "$MP/video/test.mp4" "$FILE_SIZE" || die "data gen failed on $MP"
done

# ---- nginx config -----------------------------------------------------------
CONF="$HERE/nginx_noraid.conf"
# core N -> worker_cpu_affinity mask (rightmost bit = cpu0)
MASK=$(python3 -c "print(format(1<<$NGINX_CORE,'b'))")
sudo tee "$CONF" >/dev/null <<EOF
user root;
worker_processes 1;                 # paper: nginx pinned to a single core
worker_cpu_affinity $MASK;          # core $NGINX_CORE
events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log off;

    sendfile off;
    tcp_nopush on;
    tcp_nodelay on;

    directio 4k;
    directio_alignment 4096;
    output_buffers 1 $OBUF;         # == bs that goes down to NVMe
    aio threads;

    server {
        listen 80;
        location /remote1/ { alias ${MOUNT_BASE}1/; aio threads; }
        location /remote2/ { alias ${MOUNT_BASE}2/; aio threads; }
        location /remote3/ { alias ${MOUNT_BASE}3/; aio threads; }
        location /remote4/ { alias ${MOUNT_BASE}4/; aio threads; }
    }
}
EOF

export MALLOC_MMAP_THRESHOLD_=2097152
export MALLOC_TRIM_THRESHOLD_=-1

log "[host] starting nginx (core $NGINX_CORE)"
sudo killall nginx 2>/dev/null; sleep 1
# MALLOC_* MUST be passed explicitly: sudo's env_reset strips them (even `sudo -E`
# drops MALLOC_* via its blacklist). Without the mmap-threshold bump, nginx's
# 512k–1024k output_buffers exceed glibc's default 128k mmap threshold and every
# buffer alloc/free becomes an mmap/munmap syscall — the throughput gap vs the
# manual setup_server.sh (run as root, so its `export`s reached nginx) was exactly this.
sudo MALLOC_MMAP_THRESHOLD_=2097152 MALLOC_TRIM_THRESHOLD_=-1 \
     taskset -c "$NGINX_CORE" "$NGINX_BIN" -c "$CONF" || die "nginx failed to start"
sleep 1
pgrep -a nginx | head || die "nginx not running"
sub "nginx up, serving ${MOUNT_BASE}{1..4}/video/test.mp4"
