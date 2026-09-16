#!/bin/bash
# =====================================================================
#  watchdog.sh — 호스트에서 컨테이너를 지켜본다
#
#  컨테이너가 죽으면 그 안의 알림 코드도 같이 죽어 아무것도 못 보냅니다.
#  그래서 바깥에서 감시합니다. 도커가 자동 복구하는 짧은 크래시로는
#  울리지 않도록, 연속 2회(=20분) 비정상일 때만 알립니다.
#
#  크론 : */10 * * * * /home/ubuntu/pal-fex/watchdog.sh >/dev/null 2>&1
# =====================================================================
DIR=/home/ubuntu/pal-fex
CON=palworld-fex
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

RUN=$(sudo docker inspect -f '{{.State.Running}}'        "$CON" 2>/dev/null)
HEALTH=$(sudo docker inspect -f '{{.State.Health.Status}}' "$CON" 2>/dev/null)
echo "${RUN:-missing}/${HEALTH:-none}" > "$STATE/health"

BAD=0
[ "$RUN" != "true" ] && BAD=1
[ "$HEALTH" = "unhealthy" ] && BAD=1

if [ "$BAD" = "1" ]; then
  S=$(cat "$STATE/strikes" 2>/dev/null || echo 0)
  S=$((S + 1))
  echo "$S" > "$STATE/strikes"
  if [ "$S" -ge 2 ] && [ ! -f "$STATE/alerted" ]; then
    send "⚠️ 서버 이상" "컨테이너 상태: \`${RUN:-없음}\` / 헬스: \`${HEALTH:-없음}\`
20분 넘게 비정상입니다. 서버에서 \`pal status\` 로 확인해주세요." 15158332
    touch "$STATE/alerted"
  fi
else
  if [ -f "$STATE/alerted" ]; then
    send "✅ 서버 복구" "컨테이너가 정상으로 돌아왔습니다." 3066993
    rm -f "$STATE/alerted"
  fi
  rm -f "$STATE/strikes"
fi
