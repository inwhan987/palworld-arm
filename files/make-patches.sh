#!/bin/bash
# =====================================================================
#  make-patches.sh — 이미지 원본을 꺼내 세 곳을 고쳐 patch/ 에 넣는다
#
#  1) server_manager.py   기동 완료 시 🟢 시작 알림을 보낸다
#  2) healthcheck.py      RCON 검사의 --password-stdin 을 --password 로
#  3) server_monitor.py   무인 경고를 IDLE_WARNING_ENABLED 로 제어
#
#  이미지가 바뀌면 다시 실행하면 됩니다. 실패하면 patch/ 를 건드리지
#  않고 종료하므로, 그때는 docker-compose.yml 의 ./patch/ 줄을 지우고
#  띄우면 알림만 빠진 채 정상 동작합니다.
# =====================================================================
set -e
DIR=${1:-/home/ubuntu/pal-fex}
IMG=supersunho/palworld-server:latest
OUT="$DIR/patch"
mkdir -p "$OUT"

echo "[패치] 이미지에서 원본 추출"
sudo docker pull "$IMG" >/dev/null
CID=$(sudo docker create "$IMG")
trap 'sudo docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
TMP=$(mktemp -d)
sudo docker cp "$CID:/app/src/server_manager.py"            "$TMP/server_manager.py"
sudo docker cp "$CID:/app/scripts/healthcheck.py"           "$TMP/healthcheck.py"
sudo docker cp "$CID:/app/src/monitoring/server_monitor.py" "$TMP/server_monitor.py"
sudo chown "$USER":"$USER" "$TMP"/*.py

echo "[패치] 수정 적용"
python3 - "$TMP" <<'PYEOF'
import sys, os, re
tmp = sys.argv[1]

# ---------------------------------------------- 1) 시작 알림 삽입
p = os.path.join(tmp, "server_manager.py")
src = open(p, encoding="utf-8").read()
if "patched: 기동 완료 시 디스코드 알림" in src:
    print("  server_manager.py : 이미 적용됨")
else:
    lines = src.split("\n")
    idx = None
    for i, l in enumerate(lines):
        if "Startup completed" in l and "print" in l:
            idx = i
            break
    if idx is None:
        sys.exit("!! server_manager.py 에서 'Startup completed' 출력을 찾지 못했습니다")
    pad = " " * (len(lines[idx]) - len(lines[idx].lstrip()))
    block = [
        f"{pad}# --- patched: 기동 완료 시 디스코드 알림 ---",
        f"{pad}try:",
        f"{pad}    _d = manager.get_monitoring_manager().event_dispatcher.discord_notifier",
        f"{pad}    if _d and _d.enabled:",
        f"{pad}        async with _d as _n:",
        f"{pad}            await _n.notify_server_start(language=manager.config.language)",
        f'{pad}            print("Discord notification sent: server started (patched)")',
        f"{pad}except Exception as _e:",
        f'{pad}    print(f"Discord start notify failed: {{_e}}")',
    ]
    lines[idx+1:idx+1] = block
    open(p, "w", encoding="utf-8").write("\n".join(lines))
    print("  server_manager.py : 시작 알림 삽입 완료")

# ---------------------------------------------- 2) RCON 비밀번호 전달 방식
p = os.path.join(tmp, "healthcheck.py")
src = open(p, encoding="utf-8").read()
if "--password-stdin" in src:
    src = src.replace("'--password-stdin',", "'--password', self.rcon_password,")
    src = src.replace('"--password-stdin",', '"--password", self.rcon_password,')
    open(p, "w", encoding="utf-8").write(src)
    print("  healthcheck.py    : --password 로 교체 완료")
else:
    print("  healthcheck.py    : --password-stdin 없음 (이미 수정됐거나 구조가 바뀜)")

# ---------------------------------------------- 3) 무인 경고 스위치
p = os.path.join(tmp, "server_monitor.py")
src = open(p, encoding="utf-8").read()
if "_idle_warning_enabled" in src:
    print("  server_monitor.py : 이미 적용됨")
else:
    pat = re.compile(r"if\s+current_status\.uptime\s*>\s*3600\s+and")
    if not pat.search(src):
        sys.exit("!! server_monitor.py 에서 무인 경고 조건을 찾지 못했습니다")
    src = pat.sub("if _idle_warning_enabled() and current_status.uptime > 3600 and", src, count=1)
    src += '''

def _idle_warning_enabled():
    """patched: IDLE_WARNING_ENABLED 로 무인 경고를 켜고 끕니다 (기본 꺼짐)"""
    import os
    return os.getenv("IDLE_WARNING_ENABLED", "false").strip().lower() in ("1", "true", "yes")
'''
    open(p, "w", encoding="utf-8").write(src)
    print("  server_monitor.py : 무인 경고 스위치 추가 완료")
PYEOF

echo "[패치] 문법 검사"
for f in server_manager healthcheck server_monitor; do
  python3 -m py_compile "$TMP/$f.py" || { echo "!! $f.py 문법 오류 — 중단"; exit 1; }
done

cp "$TMP"/server_manager.py "$TMP"/healthcheck.py "$TMP"/server_monitor.py "$OUT/"
rm -rf "$TMP"
echo "[패치] 완료 → $OUT"
ls -1 "$OUT"
