#!/usr/bin/env bash
# MLPerf UNet3D 데이터 디렉토리 권한 설정
#
# testdb{1,2,3,4} 와 mlperf_merged 가 root/ki 소유라
# jonghyeon이 datagen/symlink를 만들 수 없어 PermissionError가 난다.
# 이 스크립트로 소유권을 현재 유저에게 넘긴다.
#
# 사용: ./setup_permissions.sh   (sudo 비밀번호 입력 필요할 수 있음)
set -e

OWNER="$(id -un)"          # 현재 유저 (jonghyeon)
GROUP="$(id -gn)"
BASE="/mnt/rocksdb_test"

echo "소유권 대상 유저: ${OWNER}:${GROUP}"

# ── testdb1~4: datagen이 mlperf_data/ 를 만든다 (9a/9b/9c는 4 disk 고정) ──
for i in 1 2 3 4; do
    DISK="${BASE}/testdb${i}"
    if [ ! -d "$DISK" ]; then
        echo "WARNING: ${DISK} 없음 → 건너뜀"
        continue
    fi
    echo "  chown -R ${OWNER}:${GROUP} ${DISK}"
    sudo chown -R "${OWNER}:${GROUP}" "$DISK"
done

# ── mlperf_merged: symlink 머지 디렉토리 (BASE 가 ki 소유라 미리 생성 후 양도) ──
MERGED="${BASE}/mlperf_merged"
echo "  mkdir + chown ${MERGED}"
sudo mkdir -p "$MERGED"
sudo chown -R "${OWNER}:${GROUP}" "$MERGED"

echo ""
echo "── 결과 ──"
ls -ld "${BASE}"/testdb[1-4] "$MERGED" 2>/dev/null || true
echo ""
echo "완료. 이제 ./setup_4disk_simple.sh 를 sudo 없이 실행하면 된다."
