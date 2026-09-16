#!/bin/bash
# =====================================================================
#  팰월드 ARM 서버 설치
#
#  대상   : ARM64(aarch64) 우분투 22.04 / 24.04
#           오라클 Ampere A1 · 라즈베리파이 4·5 (8GB 이상 권장)
#  사용법 : bash install.sh [세이브백업.tar.gz]
#           (sudo 로 실행하지 마세요 — 필요한 곳에서만 스크립트가 씁니다)
#
#  순서   : 질문 → 설치 → 게임 내려받기 → 크론 등록 → 서버 시작
#           질문은 처음 2분 안에 끝나고, 그 뒤로는 자리를 떠도 됩니다.
# =====================================================================
set -e

REPO=https://github.com/inwhan987/palworld-arm
DIR=/home/ubuntu/pal-fex
VOL=pal-fex_pal-data
APPID=2394010
RESTORE="$1"

# ------------------------------------------------------------ 사전 점검
if [ "$(uname -m)" != "aarch64" ]; then
  echo "!! ARM64(aarch64) 전용입니다. 현재: $(uname -m)"
  echo "   x86 서버라면 FEX 에뮬레이션 없이 공식 이미지를 쓰는 게 맞습니다."
  exit 1
fi
MEM=$(free -g | awk '/^Mem:/{print $2}')
[ "${MEM:-0}" -lt 7 ] && echo "!! 경고: 메모리 ${MEM}GB — 8GB 미만이면 4인 이상에서 불안정합니다."
[ -n "$RESTORE" ] && [ ! -f "$RESTORE" ] && { echo "!! 백업 파일을 찾을 수 없습니다: $RESTORE"; exit 1; }

# 스크립트 옆에 files/ 가 있으면 그것을 쓰고, 없으면 저장소를 내려받는다
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -d "$HERE/files" ]; then
  SRC="$HERE"
else
  echo "저장소를 내려받습니다: $REPO"
  sudo apt-get update -y >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git >/dev/null
  SRC=$(mktemp -d)/repo
  git clone --depth 1 "$REPO" "$SRC"
fi

ask(){   # ask <질문> <기본값>
  local ans
  if [ -r /dev/tty ]; then read -r -p "$1" ans < /dev/tty; else read -r -p "$1" ans; fi
  echo "${ans:-$2}"
}
asksecret(){
  local ans
  if [ -r /dev/tty ]; then read -r -s -p "$1" ans < /dev/tty; else read -r -s -p "$1" ans; fi
  echo >&2
  echo "$ans"
}

# ================================================================= 질문
echo
echo "================ 서버 설정 ================"
SERVER_NAME=$(ask      "서버 이름            [팰월드 서버] : " "팰월드 서버")
SERVER_PASSWORD=$(asksecret "접속 비밀번호                 : ")
ADMIN_PASSWORD=$(asksecret  "관리자 비밀번호               : ")
DISCORD_WEBHOOK=$(ask  "디스코드 웹후크 (없으면 엔터)  : " "")
MAX_PLAYERS=$(ask      "최대 인원                 [8] : " "8")
EXP_RATE=$(ask         "경험치 배율             [1.0] : " "1.0")
CAPTURE_RATE=$(ask     "포획 확률 (최대 2.0)    [1.0] : " "1.0")

echo
echo "================ 자동 관리 ================"
CRON_HOUR=$(ask        "정기 점검 시각 (0~23)     [5] : " "5")
AUTO_UPDATE=$(ask      "업데이트 자동 적용? (y/n) [y] : " "y")
CHECK_MIN=$(ask        "업데이트 확인 주기(분)   [30] : " "30")

case "$CRON_HOUR" in ''|*[!0-9]*) CRON_HOUR=5 ;; esac
[ "$CRON_HOUR" -gt 23 ] && CRON_HOUR=5
case "$CHECK_MIN" in ''|*[!0-9]*) CHECK_MIN=30 ;; esac
[ "$CHECK_MIN" -gt 59 ] && CHECK_MIN=30
[ -z "$SERVER_PASSWORD" ] && SERVER_PASSWORD=palworld
[ -z "$ADMIN_PASSWORD" ]  && ADMIN_PASSWORD=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 12)

echo
echo "입력이 끝났습니다. 여기서부터는 자동으로 진행됩니다 (10~30분)."
echo

# ============================================================ 1. 패키지
echo "===== [1/7] 패키지 설치 ====="
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
     docker.io curl python3 tar ca-certificates
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2 2>/dev/null \
  || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent || true
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" || true

# ============================================================ 2. 파일
echo
echo "===== [2/7] 파일 배치 ====="
mkdir -p "$DIR"
cp "$SRC/files/docker-compose.yml" "$DIR/"
cp "$SRC/files/pal"                "$DIR/"
cp "$SRC/files/watchdog.sh"        "$DIR/"
cp "$SRC/files/checkupdate.sh"     "$DIR/"
cp "$SRC/files/nightly.sh"         "$DIR/"
cp "$SRC/files/make-patches.sh"    "$DIR/"
chmod +x "$DIR/pal" "$DIR"/*.sh

python3 - "$SRC/files/env.template" "$DIR/.env.palworld" <<PYEOF
import sys
src, dst = sys.argv[1], sys.argv[2]
sub = {
    "__SERVER_NAME__":     """$SERVER_NAME""",
    "__SERVER_PASSWORD__": """$SERVER_PASSWORD""",
    "__ADMIN_PASSWORD__":  """$ADMIN_PASSWORD""",
    "__DISCORD_WEBHOOK__": """$DISCORD_WEBHOOK""",
    "__MAX_PLAYERS__":     """$MAX_PLAYERS""",
    "__EXP_RATE__":        """$EXP_RATE""",
    "__CAPTURE_RATE__":    """$CAPTURE_RATE""",
}
t = open(src, encoding="utf-8").read()
for k, v in sub.items():
    t = t.replace(k, v)
open(dst, "w", encoding="utf-8").write(t)
PYEOF
chmod 600 "$DIR/.env.palworld"
echo "설정 파일 작성 완료: $DIR/.env.palworld"

# ============================================================ 3. 패치
echo
echo "===== [3/7] 코드 패치 생성 ====="
if ! bash "$DIR/make-patches.sh" "$DIR"; then
  echo "!! 패치 생성 실패 — 알림 기능 없이 진행합니다."
  sed -i '\|./patch/|d' "$DIR/docker-compose.yml"
fi

# ============================================================ 4. 기동
echo
echo "===== [4/7] 첫 기동 — 게임 본체 내려받기 (10~30분) ====="
cd "$DIR"
sudo docker compose up -d
printf "설치 대기중"
OK=0
for i in $(seq 1 120); do
  if sudo docker exec palworld-fex test -f \
     "/home/steam/palworld_server/steamapps/appmanifest_${APPID}.acf" 2>/dev/null; then
    OK=1; echo " 완료"; break
  fi
  printf "."; sleep 30
done
if [ "$OK" != "1" ]; then
  echo
  echo "!! 60분이 지나도 설치가 끝나지 않았습니다."
  echo "   sudo docker compose logs -f  로 확인하세요."
  exit 1
fi
sleep 60

# ============================================================ 5. 복원
echo
echo "===== [5/7] 세이브 복원 ====="
if [ -n "$RESTORE" ]; then
  RP=$(readlink -f "$RESTORE")
  sudo docker compose stop
  sudo docker run --rm -v "$VOL":/d -v "$(dirname "$RP")":/in alpine \
       sh -c "rm -rf /d/Pal/Saved && tar xzf /in/$(basename "$RP") -C /d"
  sudo docker run --rm -v "$VOL":/d alpine chown -R 1002:1002 /d/Pal
  sudo docker compose up -d
  echo "복원 완료: $RP"
else
  echo "백업 파일이 지정되지 않아 새 월드로 시작합니다."
fi

# ============================================================ 6. 크론
echo
echo "===== [6/7] 자동 관리 등록 ====="
if [ "$AUTO_UPDATE" = "y" ] || [ "$AUTO_UPDATE" = "Y" ]; then
  NIGHT="$DIR/nightly.sh"
else
  NIGHT="$DIR/pal restart"
fi
( echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  echo "*/10 * * * * $DIR/watchdog.sh >/dev/null 2>&1"
  echo "$CHECK_MIN * * * * $DIR/checkupdate.sh --notify >/dev/null 2>&1"
  echo "0 $CRON_HOUR * * * $NIGHT >> $DIR/restart.log 2>&1" ) | crontab -
crontab -l

if ! grep -q "alias palup=" "$HOME/.bashrc" 2>/dev/null; then
  echo "alias palup='$DIR/nightly.sh --only-update'" >> "$HOME/.bashrc"
  echo "alias pal='$DIR/pal'"                        >> "$HOME/.bashrc"
fi

# ============================================================ 7. 마무리
echo
echo "===== [7/7] 방화벽 · 서버 시작 ====="
sudo iptables -C INPUT -m state --state NEW -p udp --dport 8211 -j ACCEPT 2>/dev/null \
  || sudo iptables -I INPUT 5 -m state --state NEW -p udp --dport 8211 -j ACCEPT
sudo netfilter-persistent save 2>/dev/null || true

cd "$DIR"
sudo docker compose up -d
cp "$DIR/.env.palworld" "$DIR/.state/env.applied" 2>/dev/null || {
  mkdir -p "$DIR/.state"; cp "$DIR/.env.palworld" "$DIR/.state/env.applied"; }

IP=$(curl -s -m 10 ifconfig.me || echo "<서버IP>")
echo
echo "================================================================"
echo " 설치 완료"
echo
echo "   접속 주소   : $IP:8211"
echo "   접속 비번   : (입력하신 값)"
echo "   관리자 비번 : $ADMIN_PASSWORD"
echo "   정기 점검   : 매일 0${CRON_HOUR}시"
echo
echo "   상태 확인   : pal status"
echo "   설정 변경   : nano $DIR/.env.palworld  →  pal apply"
echo "   업데이트    : palup"
echo
echo " 클라우드 서버라면 콘솔에서 인바운드 규칙을 직접 열어야 합니다:"
echo "   프로토콜 UDP / 대상 포트 8211 / 소스 CIDR 0.0.0.0/0"
echo "   * 소스 포트 범위는 반드시 비워둘 것 (값을 넣으면 전부 차단됨)"
echo
echo " 별칭(pal, palup)을 바로 쓰려면:  source ~/.bashrc"
echo "================================================================"
