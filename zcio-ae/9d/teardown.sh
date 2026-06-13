#!/bin/bash

# ==========================================
# 변수 설정 (Setup 스크립트와 맞춰주세요)
# ==========================================
NVME_DEVS="/dev/nvme0n1 /dev/nvme0n2 /dev/nvme0n3 /dev/nvme0n4"
MD_DEV="/dev/md0"
MOUNT_POINTS="/mnt/raid0 /mnt/remote1 /mnt/remote2 /mnt/remote3 /mnt/remote4"
NGINX_CONFS="nginx_raid.conf nginx_noraid.conf"

echo "=========================================="
echo " Starting Teardown & Cleanup"
echo "=========================================="

# 1. Nginx 종료 (Graceful -> Force)
echo "[Step 1] Stopping Nginx..."
if pgrep nginx > /dev/null; then
    killall nginx 2>/dev/null
    sleep 1
    # 아직도 살아있다면 강제 종료 (좀비 프로세스 방지)
    if pgrep nginx > /dev/null; then
        echo "  - Nginx is stubborn. Force killing..."
        killall -9 nginx 2>/dev/null
    fi
    echo "  - Nginx stopped."
else
    echo "  - Nginx is not running."
fi

# 2. 마운트 경로 사용 중인 프로세스 정리 (중요)
echo "[Step 2] Clearing processes on mount points..."
for mp in $MOUNT_POINTS; do
    if mountpoint -q $mp; then
        # 해당 폴더를 점유 중인 프로세스(예: 켜놓은 쉘, tail 등) 강제 종료
        fuser -km $mp 2>/dev/null
    fi
done

# 3. 파일시스템 마운트 해제
echo "[Step 3] Unmounting filesystems..."
for mp in $MOUNT_POINTS; do
    if mountpoint -q $mp; then
        umount $mp
        echo "  - Unmounted: $mp"
    fi
    # 빈 디렉토리 삭제 (선택사항)
    # rmdir $mp 2>/dev/null
done

# 4. RAID 장치 정지 및 초기화
echo "[Step 4] Stopping RAID array..."
if [ -e $MD_DEV ]; then
    mdadm --stop $MD_DEV 2>/dev/null
    echo "  - RAID device ($MD_DEV) stopped."
    
    # 다음 실험을 위해 슈퍼블록(RAID 메타데이터) 삭제 -> 깨끗한 SSD 상태로 복구
    echo "  - Zeroing superblocks on NVMe devices..."
    for dev in $NVME_DEVS; do
        mdadm --zero-superblock $dev 2>/dev/null
    done
else
    echo "  - No RAID device found."
fi

# 5. 시스템 설정 복구 (IRQ Balance)
echo "[Step 5] Restoring System Settings..."
# IRQ Pinning을 해제하고 OS가 알아서 관리하도록 복구
systemctl start irqbalance
if systemctl is-active --quiet irqbalance; then
    echo "  - irqbalance service restarted."
else
    echo "  - Warning: Failed to restart irqbalance."
fi

# 6. 임시 파일 청소
echo "[Step 6] Cleaning up config/log files..."
rm -f $NGINX_CONFS
rm -f *.log
# wrk 로그 파일 등도 삭제
rm -f res_d*.log result_*.log

echo "=========================================="
echo " Teardown Complete! System is clean."
echo "=========================================="
