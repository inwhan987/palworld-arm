#!/bin/bash
# =====================================================================
#  nightly.sh — 정기 점검
#
#    nightly.sh                 업데이트 있으면 적용, 없으면 재시작 (크론용)
#    nightly.sh --only-update   업데이트 있을 때만 적용, 없으면 아무것도 안 함
# =====================================================================
DIR=/home/ubuntu/pal-fex
cd "$DIR" || exit 1
ONLY=0
[ "$1" = "--only-update" ] && ONLY=1

"$DIR/checkupdate.sh"      # 0=최신  1=업데이트있음  2=확인실패
rc=$?

if [ "$rc" = "1" ]; then
  echo "=== $(date '+%F %T') 업데이트 발견 -> update-game 실행 ==="
  "$DIR/pal" update-game -y
  exit $?
fi

if [ "$ONLY" = "1" ]; then
  [ "$rc" = "2" ] && { echo "버전 확인 실패 - 아무것도 하지 않음"; exit 2; }
  echo "이미 최신 - 아무것도 하지 않음"
  exit 0
fi

[ "$rc" = "2" ] && echo "=== $(date '+%F %T') 버전 확인 실패 -> 재시작만 진행 ==="
echo "=== $(date '+%F %T') 정기 재시작 ==="
"$DIR/pal" restart
