#!/bin/bash
# rgss-check: RPG Maker XP·VX·VX Ace 게임을 Ruby 프로필별로 시뮬레이터에서 시작 화면까지 돌려 보고 기록한다.
# 설명·옵션: tools/rgss-check/README.md
set -u
export LC_ALL=${LC_ALL:-en_US.UTF-8}

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUNDLE=com.minwoo.bingsu

UDID=""
APP=""
OUT=""
LABEL="build"
PROFILES="auto 18 31"
T1=20          # 첫 스크린숏 (실행 뒤 초)
KEYS="24:KeyC,27:KeyC"   # BINGSU_KEYS: 게임 화면이 뜬 뒤 그 시각(초)에 확인 키
T2=34          # 둘째 스크린숏 (키 누른 뒤)
PROBE=1
WORK=""
STAGE2=""
GAMES=()
NO_DEFAULT=0
CLEAN=0
LOCAL=0
EXTRA_ENV=()

usage() {
  sed -n '1,200p' "$HERE/README.md" | sed -n '/^## 쓰는 법/,/^## /p'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--device) UDID="$2"; shift 2 ;;
    -a|--app) APP="$2"; shift 2 ;;
    -o|--out) OUT="$2"; shift 2 ;;
    -l|--label) LABEL="$2"; shift 2 ;;
    -p|--profiles) PROFILES="$2"; shift 2 ;;
    --t1) T1="$2"; shift 2 ;;
    --t2) T2="$2"; shift 2 ;;
    --keys) KEYS="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --stage) STAGE2="$2"; shift 2 ;;
    --no-probe) PROBE=0; shift ;;
    --only) NO_DEFAULT=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --local) LOCAL=1; shift ;;
    -e|--env) EXTRA_ENV+=("SIMCTL_CHILD_$2"); shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "모르는 옵션: $1" >&2; usage 1 ;;
    *) GAMES+=("$1"); shift ;;
  esac
done

[ -n "$UDID" ] || { echo "시뮬레이터 UDID 를 -d 로 주세요 (다른 세션이 쓰는 기기는 피할 것)" >&2; exit 1; }
[ -n "$WORK" ] || WORK="${TMPDIR:-/tmp}/rgss-check-work"
[ -n "$OUT" ] || OUT="$WORK/results/$(date +%Y%m%d-%H%M%S)-$LABEL"
mkdir -p "$OUT" "$WORK"
OUT="$(cd "$OUT" && pwd)"

log() { echo "[rgss-check] $*" >&2; }

is_rgss() {  # 게임 폴더인가: Game.ini 와 스크립트(또는 암호화 아카이브)
  local g="$1"
  [ -f "$g/Game.ini" ] || [ -f "$g/game.ini" ] || return 1
  ls "$g" "$g/Data" 2>/dev/null | grep -qiE '^(scripts\.(rxdata|rvdata2?)|game\.rgss(ad|2a|3a))$'
}

# 기본 게임 목록: 저장소 맨 위 RPG Maker 폴더 + Games/ 안 RGSS 게임 (zip 은 WORK 에 풀어서)
if [ "$NO_DEFAULT" = 0 ]; then
  for d in "$REPO"/*/ "$REPO"/Games/*/ "$REPO"/Games/*/*/; do
    d="${d%/}"; is_rgss "$d" && GAMES+=("$d")
  done
  for z in "$REPO"/Games/*/*/*.zip; do
    [ -f "$z" ] || continue
    name="$(basename "$z" .zip)"
    case "$name" in RPGVXAce*|RPGVX*|RTP*) continue ;; esac   # RTP 는 게임이 아님
    dest="$WORK/unzipped/$name"
    if [ ! -d "$dest" ]; then
      log "풀기: $z"
      mkdir -p "$dest" && ditto -x -k "$z" "$dest" || { rm -rf "$dest"; continue; }
    fi
    # zip 안에 폴더 하나만 있으면 그 폴더가 게임
    g="$dest"
    if ! is_rgss "$g"; then
      sub="$(find "$dest" -mindepth 1 -maxdepth 2 -iname Game.ini -print -quit)"
      [ -n "$sub" ] && g="$(dirname "$sub")"
    fi
    is_rgss "$g" && GAMES+=("$g")
  done
fi
[ ${#GAMES[@]} -gt 0 ] || { echo "게임 폴더가 없습니다" >&2; exit 1; }

# 앱 설치 (주면)
if [ -n "$APP" ]; then
  log "설치: $APP → $UDID"
  xcrun simctl install "$UDID" "$APP" || exit 1
fi
DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)" || { echo "빙수가 설치돼 있지 않습니다 (-a 로 앱 경로)" >&2; exit 1; }

# 점검용 복제본 만들기: <게임 상위>/.rgss-check-stage/<id>/<id> (APFS 복제라 공간을 거의 안 씀).
# 앱은 BINGSU_DEV_GAMES 폴더 안 게임을 모두 훑으므로 게임마다 따로 둔다.
# mkxp.json 이 있으면 복제본의 preloadScript 에 probe.rb 를 붙인다(원본은 그대로)
stage() {
  local g="$1" id; id="$(basename "$g")"
  # 먼저 WORK 안에, 볼륨이 달라 복제가 안 되면 게임 옆 숨김 폴더에 (복사는 하지 않는다 — 내장 디스크 여유가 적음)
  local root=""
  local cands=("$WORK/stage/$id")
  [ -n "$STAGE2" ] && cands+=("$STAGE2/$id")
  cands+=("$(dirname "$g")/.rgss-check-stage/$id")
  for cand in "${cands[@]}"; do
    if [ -d "$cand/$id" ]; then root="$cand"; break; fi
    mkdir -p "$cand"
    # cp -c 는 볼륨이 다르면 말없이 그냥 복사하므로 장치 번호를 먼저 본다
    if [ "$(stat -f %d "$g")" = "$(stat -f %d "$cand")" ] && cp -c -R "$g" "$cand/$id"; then root="$cand"; break; fi
    rm -rf "$cand"; rmdir "$(dirname "$cand")" 2>/dev/null
  done
  [ -n "$root" ] || { log "복제(cp -c) 실패: $g"; return 1; }
  cp "$HERE/probe.rb" "$root/rgss-check-probe.rb"
  local mk; mk="$(ls "$root/$id" | grep -i '^mkxp\.json$' | head -1)"
  if [ "$PROBE" = 1 ] && [ -n "$mk" ]; then
    # 원본 mkxp.json 에서 다시 만들어 매번 같은 상태로
    ruby -rjson -e '
      src, dst, probe = ARGV
      t = File.read(src, encoding: "UTF-8")
      # // 주석 줄과 끝 쉼표(JSON5 식)를 빼고 읽는다
      j = JSON.parse(t.lines.reject { |l| l.strip.start_with?("//") }.join.gsub(/,(\s*[}\]])/, "\\1"))
      j["preloadScript"] = (j["preloadScript"] || []).reject { |s| s.include?("rgss-check-probe") } + [probe]
      File.write(dst, JSON.pretty_generate(j))
    ' "$g/$mk" "$root/$id/$mk" "$root/rgss-check-probe.rb" || log "probe 넣기 실패: $g"
  elif [ -n "$mk" ]; then
    cp "$g/$mk" "$root/$id/$mk"
  fi
  echo "$root"
}

run_one() {
  local g="$1" prof="$2" root="$3" auto="$4" isauto="${5:-}"
  local id; id="$(basename "$g")"
  local slug; slug="$(echo "$id" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')"
  local dir="$OUT/$slug/ruby-$prof"
  mkdir -p "$dir"
  log "실행: $id · ruby=$prof"
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
  rm -f "$DATA/tmp/brassbowl.log"
  local start; start="$(date '+%Y-%m-%d %H:%M:%S')"
  local envs=(SIMCTL_CHILD_BINGSU_DEV_GAMES="$root" SIMCTL_CHILD_BINGSU_OPEN="$id"
              SIMCTL_CHILD_BINGSU_MKXP_LOG=1 SIMCTL_CHILD_BINGSU_FORCE_PAD=1)
  [ "$isauto" != auto ] && envs+=(SIMCTL_CHILD_BINGSU_RUBY="$prof")
  [ -n "$KEYS" ] && envs+=(SIMCTL_CHILD_BINGSU_KEYS="$KEYS")
  [ ${#EXTRA_ENV[@]} -gt 0 ] && envs+=("${EXTRA_ENV[@]}")
  env "${envs[@]}" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null || log "실행 실패"
  sleep "$T1"
  xcrun simctl io "$UDID" screenshot "$dir/shot1.png" >/dev/null 2>&1
  sleep $((T2 - T1))
  xcrun simctl io "$UDID" screenshot "$dir/shot2.png" >/dev/null 2>&1
  xcrun simctl spawn "$UDID" log show --start "$start" --style compact \
    --predicate 'process == "Bingsu"' 2>/dev/null | grep -E '\[BrassBowl\]|\[Bowl\]' > "$dir/app.log"
  cp "$DATA/tmp/brassbowl.log" "$dir/engine.log" 2>/dev/null || : > "$dir/engine.log"
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
  ruby -rjson -e 'puts JSON.generate(game: ARGV[0], id: ARGV[1], profile: ARGV[2], auto: ARGV[3], label: ARGV[4], probe: ARGV[5] == "1")' \
    "$g" "$id" "$prof" "$auto" "$LABEL" "$PROBE" > "$dir/meta.json"
}

log "기기 $UDID · 결과 $OUT · 프로필 [$PROFILES] · 게임 ${#GAMES[@]}개"
for g in "${GAMES[@]}"; do
  id="$(basename "$g")"
  slug="$(echo "$id" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')"
  mkdir -p "$OUT/$slug"
  ruby -W0 "$HERE/scan.rb" "$g" > "$OUT/$slug/scan.json" || { log "읽기 실패: $g"; continue; }
  auto="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0]))["auto"]' "$OUT/$slug/scan.json")"
  rgss="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0]))["rgss"]' "$OUT/$slug/scan.json")"
  # --local: WORK 와 다른 볼륨(느린 외장 디스크 등)의 게임은 WORK 로 진짜 복사해 돌리고 끝나면 지운다.
  # 엔진은 시작할 때 게임 파일을 모두 훑는다(createPathCache) — ~/Dev 디스크 이미지에서는 2만 개에 몇 분이 걸려
  # 시간 안에 Ruby 가 시작되지 않았다(2026-11-14)
  src="$g"; copied=""
  if [ "$LOCAL" = 1 ] && [ "$(stat -f %d "$g")" != "$(stat -f %d "$WORK")" ]; then
    need=$(du -sk "$g" | cut -f1); free=$(df -k "$WORK" | awk 'NR==2{print $4}')
    if [ $((need + 1048576)) -gt "$free" ]; then
      log "자리가 모자라 복사 안 함 (필요 $((need/1024))MB + 1GB 여유, 남은 $((free/1024))MB): $g"
    else
      log "내장 디스크로 복사: $g"
      mkdir -p "$WORK/local"
      ditto "$g" "$WORK/local/$id" && { src="$WORK/local/$id"; copied="$src"; }
    fi
  fi
  root="$(stage "$src")" || continue
  # 프로필: auto 는 자동 판별값으로 바꿔 같은 값은 한 번만. VX Ace 면 19 도
  # auto 실행은 BINGSU_RUBY 를 넘기지 않는다 — 빙수가 스스로 고르는 길(RubyProfile.detect)을 그대로 본다.
  # 같은 값을 직접 고른 프로필은 auto 와 겹치면 뺀다
  todo=(); auto_run=0
  for p in $PROFILES $( [ "$rgss" = 3 ] && echo 19 ); do
    if [ "$p" = auto ]; then auto_run=1; continue; fi
    [ "$p" = "$auto" ] && [ "$auto_run" = 1 ] && continue
    case " ${todo[*]:-} " in *" $p "*) ;; *) todo+=("$p") ;; esac
  done
  if [ "$auto_run" = 1 ]; then
    todo=($(for p in "${todo[@]:-}"; do [ -n "$p" ] && [ "$p" != "$auto" ] && echo "$p"; done))
    run_one "$g" "$auto" "$root" "$auto" auto
  fi
  for p in "${todo[@]:-}"; do [ -n "$p" ] && run_one "$g" "$p" "$root" "$auto"; done
  if [ -n "$copied" ]; then rm -rf "$copied" "$root"; fi
done

ruby -W0 "$HERE/report.rb" "$OUT" > "$OUT/report.md"
# --clean: 게임 옆에 만든 숨김 복제 폴더를 지운다 (복제라 원본에는 영향 없음)
if [ "$CLEAN" = 1 ]; then
  for g in "${GAMES[@]}"; do
    s="$(dirname "$g")/.rgss-check-stage"
    [ -d "$s" ] && { log "지움: $s"; rm -rf "$s"; }
    [ -n "$STAGE2" ] && [ -d "$STAGE2/$(basename "$g")" ] && { log "지움: $STAGE2/$(basename "$g")"; rm -rf "$STAGE2/$(basename "$g")"; }
  done
fi
log "표: $OUT/report.md"
