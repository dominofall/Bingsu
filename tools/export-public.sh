#!/bin/sh
# 공개 저장소용 사본 만들기 (2026-10-30 결정: 공개 저장소는 새 기록 하나로 시작, 계획·작업 메모·디자인 보드는 빼고 중립 문구로).
# 로컬 저장소의 지금 커밋(HEAD)을 빈 폴더에 풀고, 공개하지 않는 파일을 빼고, 금지 항목이 없는지 검사한 뒤
# 새 git 저장소에 커밋 하나로 담는다. push 는 하지 않는다.
#
#   AUTHOR="이름 <아이디@users.noreply.github.com>" sh tools/export-public.sh [대상 폴더]
#
# 대상 폴더 기본값: 저장소 옆 Bingsu-public. 이미 있으면 멈춘다(덮어쓰지 않음).
set -eu

ROOT=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)
DEST=${1:-"$ROOT/../Bingsu-public"}
: "${AUTHOR:?AUTHOR=\"이름 <아이디@users.noreply.github.com>\" 를 넘겨 주세요}"

if [ -e "$DEST" ]; then echo "이미 있어요: $DEST (지우거나 다른 폴더를 주세요)"; exit 1; fi
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then echo "커밋 안 한 변경이 있어요. 먼저 커밋하세요"; exit 1; fi

# 공개하지 않는 것: 계획서·세션 메모(팬게임 분석·내부 결정), 디자인 보드(게임 화면 캡처 포함), 엔진 PoC 기록,
# TestFlight 제출 메모(심사 메모·내부 링크), 심사 확인용 게임(기획·제작 메모. 게임은 mino-bingsu 저장소로 따로 배포)
EXCLUDE="PLAN.md NEXT_SESSION.md design docs/phase3-mkxp-poc.md docs/beta/testflight-info.md docs/review-game tools/review-game"

mkdir -p "$DEST"
git -C "$ROOT" archive --format=tar HEAD | tar -x -C "$DEST"
for p in $EXCLUDE; do rm -rf "${DEST:?}/$p"; done

# 금지 항목 검사 (PLAN 8장: 게임 원본·추출물·저장 데이터·서명 파일·키·개인 경로)
fail=0
bad=$(cd "$DEST" && find . -type f \( -iname '*.asar' -o -iname '*.exe' -o -iname '*.dll' -o -iname '*.rxdata' -o -iname '*.rvdata*' \
      -o -iname '*.rgss*' -o -iname '*.p8' -o -iname '*.p12' -o -iname '*.mobileprovision' -o -iname '*.cer' -o -iname '*.zip' \
      -o -path '*/Games/*' -o -path '*/Saves/*' -o -path '*/Keys/*' -o -iname 'board_server_address.txt' \) | head -20)
[ -z "$bad" ] || { echo "금지 파일:"; echo "$bad"; fail=1; }
# 심볼릭 링크는 위 검사(-type f)를 빠져나가고, 저장소 밖을 가리킬 수 있다
links=$(cd "$DEST" && find . -type l | head -20)
[ -z "$links" ] || { echo "심볼릭 링크:"; echo "$links"; fail=1; }
# 토큰 모양의 값 (파일 이름만 출력한다)
tokens=$(grep -rIlE 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|BEGIN (RSA |OPENSSH )?PRIVATE KEY' "$DEST" | grep -v '/tools/export-public.sh$' || true)
[ -z "$tokens" ] || { echo "토큰 모양의 값이 든 파일:"; echo "$tokens"; fail=1; }
if grep -rIl -e '/Users/' -e 'BEGIN PRIVATE KEY' -e 'BEGIN EC PRIVATE KEY' "$DEST" | grep -v '/tools/export-public.sh$' | head -5 | grep -q .; then
    echo "개인 경로·키가 든 파일:"; grep -rIl -e '/Users/' -e 'BEGIN PRIVATE KEY' -e 'BEGIN EC PRIVATE KEY' "$DEST" | grep -v '/tools/export-public.sh$'; fail=1
fi
# 팀 ID·API 키 ID 는 Keys/ 에서 읽어 값이 들어갔는지만 본다 (값은 출력하지 않음)
if [ -f "$ROOT/Keys/LOCAL_NOTES.md" ]; then
    team=$(sed -n '3p' "$ROOT/Keys/LOCAL_NOTES.md" | grep -oE '[A-Z0-9]{10}' | head -1 || true)
    [ -z "$team" ] || ! grep -rqF "$team" "$DEST" || { echo "팀 ID 가 든 파일이 있어요"; fail=1; }
    # Issuer ID 와 실기기·시뮬레이터 UDID: 메모에 적힌 UUID 모양의 값을 모두 본다 (값은 출력하지 않음)
    for id in $(grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4,16}(-[0-9A-Fa-f]{4}){0,3}(-[0-9A-Fa-f]{12})?' "$ROOT/Keys/LOCAL_NOTES.md" | sort -u); do
        ! grep -rqF "$id" "$DEST" || { echo "메모의 식별자(Issuer ID·UDID)가 든 파일이 있어요"; fail=1; break; }
    done
fi
for k in "$ROOT"/Keys/AuthKey_*.p8; do
    [ -f "$k" ] || continue
    kid=$(basename "$k" .p8 | sed 's/AuthKey_//')
    ! grep -rqF "$kid" "$DEST" || { echo "API 키 ID 가 든 파일이 있어요"; fail=1; }
done
# Google OAuth 클라이언트 ID: 로컬 Secrets.xcconfig(gitignore)에만 둔다. 사본에 그 파일이나 실제 모양의 ID 가 있으면 멈춘다
# (예시 파일의 <숫자>-<문자> 자리표시는 통과). 값은 출력하지 않는다
[ ! -e "$DEST/BingsuApp/Secrets.xcconfig" ] || { echo "Secrets.xcconfig 가 들어 있어요"; fail=1; }
if grep -rIqE '[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com' "$DEST"; then echo "Google 클라이언트 ID 모양의 값이 든 파일이 있어요"; fail=1; fi
if [ -f "$ROOT/Keys/LOCAL_NOTES.md" ]; then
    cid=$(sed -n '8p' "$ROOT/Keys/LOCAL_NOTES.md" | grep -oE '[0-9]+-[a-z0-9]+' | head -1 || true)
    [ -z "$cid" ] || ! grep -rqF "$cid" "$DEST" || { echo "Google 클라이언트 ID 가 든 파일이 있어요"; fail=1; }
fi
if [ "$fail" -ne 0 ]; then echo "공개본을 만들지 않았어요. $DEST 를 지우고 고친 뒤 다시"; exit 1; fi

git -C "$DEST" init -q -b main
git -C "$DEST" add -A
name=$(echo "$AUTHOR" | sed -E 's/ *<.*//'); mail=$(echo "$AUTHOR" | sed -E 's/.*<(.*)>.*/\1/')
GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$mail" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$mail" \
    git -C "$DEST" commit -q -m "빙수 공개 (로컬 $(git -C "$ROOT" rev-parse --short HEAD) 기준)"
echo "공개본: $DEST ($(git -C "$DEST" ls-files | wc -l | tr -d ' ')개 파일, 커밋 1개). push 는 직접 확인한 뒤에"
