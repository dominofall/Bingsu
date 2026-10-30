#!/bin/sh
# Xcode 빌드 단계: build-framework.sh 가 만든 BrassBowl.framework 를 앱의 Frameworks/ 에 넣고 서명한다.
# 앱은 이 프레임워크를 링크하지 않고 실행 중에 dlopen 한다. 없으면 경고만 하고 넘어간다
# (그 빌드에서는 RPG Maker XP 게임이 "이 빌드에는 RPG Maker XP 실행기가 없어요"로 보인다).
set -eu

SRC="$SRCROOT/build/BrassBowl/$PLATFORM_NAME/BrassBowl.framework"
DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"

if [ ! -f "$SRC/BrassBowl" ]; then
    echo "warning: BrassBowl.framework($PLATFORM_NAME) 없음 — RPG Maker XP 실행기 빠진 빌드. BingsuApp/BrassBowl/README.md 참고"
    rm -rf "$DEST/BrassBowl.framework"
    exit 0
fi

mkdir -p "$DEST"
rsync -a --delete "$SRC" "$DEST/"
SIGN="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$SIGN" ] || SIGN="-"
codesign --force --sign "$SIGN" --timestamp=none --preserve-metadata=identifier "$DEST/BrassBowl.framework"
echo "BrassBowl.framework 넣음 ($PLATFORM_NAME)"
