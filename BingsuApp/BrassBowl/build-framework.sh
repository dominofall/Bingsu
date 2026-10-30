#!/bin/sh
# 놋그릇(BrassBowl) — RPG Maker XP 엔진 mkxp-z(iOS 포크, GPLv3)를 빙수가 dlopen 하는 동적 프레임워크로 링크한다.
#
# 빙수 본체는 엔진을 링크하지 않는다. RPG Maker XP 게임을 열 때 BrassBowl/BrassBowlEngine.swift 가
# Frameworks/BrassBowl.framework/BrassBowl 을 dlopen 한다(empo-app 의 MkxpCore.framework 와 같은 구조).
# 내보내는 이름은 mkxp_* 뿐이고, Ruby 세 벌·SDL·OpenAL 등은 프레임워크 안에 숨는다.
#
# 엔진 소스·빌드는 저장소 밖(기본 ~/Dev/vendor/mkxp-z-apple-mobile, 태그 v9)에서 한다. 순서는 BrassBowl/README.md.
# 결과물은 BingsuApp/build/BrassBowl/<sdk>/BrassBowl.framework (gitignore). 서드파티 바이너리는 커밋하지 않는다.
#
# 사용: BingsuApp/BrassBowl/build-framework.sh [iphonesimulator|iphoneos]
set -eu

SDK="${1:-iphonesimulator}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="${MKXP_SRC:-$HOME/Dev/vendor/mkxp-z-apple-mobile}"
ARCH=arm64
# 빙수 앱과 같은 iOS 26 (포크 기본값 그대로, deps/*.make MINIMUM_REQUIRED)
MIN_OS=26.0

case "$SDK" in
    iphoneos) TARGET="$ARCH-apple-ios$MIN_OS"; PLATFORM=iPhoneOS ;;
    iphonesimulator) TARGET="$ARCH-apple-ios$MIN_OS-simulator"; PLATFORM=iPhoneSimulator ;;
    *) echo "build-framework: sdk 는 iphonesimulator 또는 iphoneos" >&2; exit 2 ;;
esac

TREE="$ENGINE/deps/build-$SDK-$ARCH"
LIB="$TREE/lib"
ANGLE="$ENGINE/deps/ANGLE/$SDK"
OUT="$HERE/../build/BrassBowl/$SDK"
FW="$OUT/BrassBowl.framework"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"

for f in libmkxpz-core.a mkxp18-merged.o mkxp19-merged.o mkxp31-merged.o libSDL2.a libruby.3.1-static.a; do
    [ -f "$LIB/$f" ] || { echo "build-framework: $LIB/$f 없음. BrassBowl/README.md 순서대로 엔진을 먼저 빌드" >&2; exit 1; }
done

# MIDI: 포크에는 fluidsynth 가 없다. build-fluidsynth.sh 로 만든 정적 fluidsynth 가 있으면 같이 링크한다
# (엔진 코어를 SHARED_FLUID 로 다시 빌드해야 쓰인다 — README 의 MIDI 절)
FLUID=""
if [ -f "$LIB/libfluidsynth.a" ]; then
    FLUID="-lfluidsynth"
    echo "[BrassBowl] fluidsynth 포함"
fi

rm -rf "$FW"
mkdir -p "$FW"

echo "[BrassBowl] $SDK 링크 중..."
# -force_load: app_bridge.h 함수 대부분은 링크 안에서 아무도 부르지 않아 빠지기 쉽다(포크 package-ios.sh 와 같은 이유)
# shellcheck disable=SC2086
"$CXX" -dynamiclib -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -install_name "@rpath/BrassBowl.framework/BrassBowl" \
    -Wl,-exported_symbols_list,"$HERE/brassbowl.exports" \
    -Wl,-dead_strip \
    -L"$LIB" -L"$ANGLE/lib" \
    -o "$FW/BrassBowl" \
    -Wl,-force_load,"$LIB/libmkxpz-core.a" \
    "$LIB/mkxp18-merged.o" "$LIB/mkxp19-merged.o" "$LIB/mkxp31-merged.o" \
    -lSDL2 -lSDL2_image -lSDL2_sound -lSDL2_ttf -lfreetype -lpixman-1 -lpng16 \
    -logg -lvorbis -lvorbisfile -ltheora -ltheoradec -lphysfs -luchardet \
    -lopenal -lssl -lcrypto $FLUID -lz -lbz2 -liconv \
    -lANGLE_static -lEGL_static -lGLESv2_static \
    -framework Foundation -framework UIKit -framework CoreFoundation \
    -framework CoreGraphics -framework CoreVideo -framework CoreAudio \
    -framework AudioToolbox -framework AVFoundation -framework Metal \
    -framework QuartzCore -framework GameController -framework CoreMotion \
    -framework IOSurface -weak_framework CoreBluetooth -weak_framework CoreHaptics

# 엔진은 자기 바이너리 옆의 Assets.bundle·Ruby/ 를 dladdr 로 찾는다(src/filesystem/filesystemImplIOS.mm)
A="$FW/Assets.bundle"
mkdir -p "$A/Shaders" "$A/Fonts" "$A/Preload" "$A/Postload"
cp "$ENGINE"/shader/*.frag "$ENGINE"/shader/*.vert "$ENGINE"/shader/*.h "$A/Shaders/"
cp "$ENGINE"/assets/liberation.ttf "$ENGINE"/assets/wqymicrohei.ttf "$A/Fonts/"
cp "$ENGINE"/assets/gamecontrollerdb.txt "$ENGINE"/assets/icon.png "$ENGINE"/assets/cacert.pem "$A/"
cp "$ENGINE"/scripts/preload/*.rb "$A/Preload/"
cp "$ENGINE"/scripts/postload/*.rb "$A/Postload/"
cp -R "$TREE/ruby-stdlib" "$FW/Ruby"
# 딸린 라이브러리 라이선스 목록. 앱 안 "오픈소스 라이선스" 화면이 이 파일을 읽어 보여 준다.
# 포크 목록에 빠진 ANGLE·libpng·FluidSynth 는 extra-licenses.json 에서 덧붙인다
python3 - "$TREE/licenses.json" "$HERE/extra-licenses.json" "$FW/licenses.json" <<'PY'
import json, sys
src, extra, out = sys.argv[1:4]
items = json.load(open(src)) + json.load(open(extra))
json.dump(items, open(out, "w"), ensure_ascii=False)
PY

COMMIT="$(git -C "$ENGINE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
cat >"$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>ko</string>
	<key>CFBundleExecutable</key><string>BrassBowl</string>
	<key>CFBundleIdentifier</key><string>com.minwoo.bingsu.brassbowl</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>BrassBowl</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$PLATFORM</string></array>
	<key>MinimumOSVersion</key><string>$MIN_OS</string>
	<key>BrassBowlEngineCommit</key><string>$COMMIT</string>
</dict>
</plist>
PLIST

echo "[BrassBowl] 완료: $FW ($(du -sh "$FW" | cut -f1), 엔진 $COMMIT)"
