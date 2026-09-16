#!/bin/bash
# =====================================================================
#  checkupdate.sh — 설치된 빌드와 스팀 최신 빌드를 비교한다
#
#    checkupdate.sh            결과만 출력
#    checkupdate.sh --notify   업데이트가 있으면 디스코드 알림 (빌드당 1회)
#
#  종료 코드 : 0=최신  1=업데이트있음  2=확인실패
# =====================================================================
DIR=/home/ubuntu/pal-fex
APPID=2394010
CON=palworld-fex
VOL=pal-fex_pal-data
STATE="$DIR/.state"; mkdir -p "$STATE"
HOOK=$(grep -E '^DISCORD_WEBHOOK_URL=' "$DIR/.env.palworld" | cut -d= -f2-)

send(){
  [ -n "$HOOK" ] || return 0
  python3 -c '
import sys, json, datetime
print(json.dumps({"embeds":[{"title":sys.argv[1],"description":sys.argv[2],
 "color":int(sys.argv[3]),
 "timestamp":datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z")}]}))
' "$1" "$2" "$3" | curl -s -H "Content-Type: application/json" --data-binary @- "$HOOK" >/dev/null
}

# 설치된 빌드 — 컨테이너가 꺼져 있어도 읽히도록 볼륨에서 직접
ACF="/var/lib/docker/volumes/${VOL}/_data/steamapps/appmanifest_${APPID}.acf"
CUR=$(sudo grep -m1 '"buildid"' "$ACF" 2>/dev/null | tr -d '"' | awk '{print $2}')
[ -n "$CUR" ] || CUR=$(sudo docker exec "$CON" grep -m1 '"buildid"' \
  "/home/steam/palworld_server/steamapps/appmanifest_${APPID}.acf" 2>/dev/null \
  | tr -d '"' | awk '{print $2}')

# 스팀 최신 빌드
NEW=$(curl -s -m 15 "https://api.steamcmd.net/v1/info/${APPID}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['${APPID}']['depots']['branches']['public']['buildid'])" 2>/dev/null)

if [ -z "$CUR" ] || [ -z "$NEW" ]; then
  echo "확인 실패 (설치=${CUR:-?} / 최신=${NEW:-?})"
  exit 2
fi

if [ "$CUR" = "$NEW" ]; then
  echo "최신입니다 (빌드 $CUR)"
  rm -f "$STATE/update.notified"
  exit 0
fi

echo "업데이트 있음:  설치 $CUR  ->  최신 $NEW"
echo "  적용:  pal update-game   또는   palup"

if [ "$1" = "--notify" ]; then
  [ "$(cat "$STATE/update.notified" 2>/dev/null)" = "$NEW" ] && exit 1
  send "🔔 팰월드 업데이트 발견" "설치된 빌드: \`$CUR\`
최신 빌드: \`$NEW\`

새벽 정기 점검 때 자동으로 적용됩니다.
지금 바로 적용하려면 서버에서 \`palup\` 을 실행하세요." 16752640
  echo "$NEW" > "$STATE/update.notified"
fi
exit 1
