#!/bin/sh
# MIDI 합성기 FluidSynth(LGPL-2.1)를 iOS 용 정적 라이브러리로 빌드한다.
#
# mkxp-z iOS 포크에는 fluidsynth 가 없어(실행 중 @rpath/libfluidsynth.dylib 를 찾다 실패 → MIDI 무음)
# MIDI BGM 을 쓰는 게임(게임에 든 .sf2 사운드폰트)이 무음이 된다.
# 여기서 만든 libfluidsynth.a 를 엔진 코어와 함께 BrassBowl.framework 안에 정적으로 넣고,
# 코어는 SHARED_FLUID 로 다시 빌드해 dlopen 대신 직접 부르게 한다(README 의 MIDI 절).
# glib 없이 C++ 스레드(osal=cpp11, FluidSynth 2.4+)로, 오디오 드라이버·네트워크 등은 모두 끈다(합성만 씀).
# iOS 에서는 CMake 가 실행 파일(fluidsynth 명령)을 번들로 만들어 install 규칙이 깨지므로 MACOSX_BUNDLE 을 끈다(라이브러리만 씀).
#
# 사용: BingsuApp/BrassBowl/build-fluidsynth.sh [iphonesimulator|iphoneos]
#   소스: ${FLUID_SRC:-~/Dev/vendor/fluidsynth} (태그 v2.5.7)
#   결과: <엔진>/deps/build-<sdk>-arm64/{lib/libfluidsynth.a, include/fluidsynth.h, include/fluidsynth/}
set -eu

SDK="${1:-iphonesimulator}"
SRC="${FLUID_SRC:-$HOME/Dev/vendor/fluidsynth}"
ENGINE="${MKXP_SRC:-$HOME/Dev/vendor/mkxp-z-apple-mobile}"
PREFIX="$ENGINE/deps/build-$SDK-arm64"
WORK="$SRC/build-$SDK"
MIN_OS=26.0

[ -f "$SRC/CMakeLists.txt" ] || { echo "build-fluidsynth: $SRC 에 소스 없음 (git clone --depth 1 --branch v2.5.7 https://github.com/FluidSynth/fluidsynth.git)" >&2; exit 1; }

rm -rf "$WORK"
cmake -S "$SRC" -B "$WORK" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_OS" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -Dosal=cpp11 -Denable-threads=off -Denable-openmp=off -Denable-native-dls=off \
    -Denable-alsa=off -Denable-aufile=off -Denable-dbus=off -Denable-ipv6=off -Denable-jack=off \
    -Denable-ladspa=off -Denable-libinstpatch=off -Denable-libsndfile=off -Denable-midishare=off \
    -Denable-network=off -Denable-oss=off -Denable-sdl3=off -Denable-pulseaudio=off -Denable-pipewire=off \
    -Denable-readline=off -Denable-coreaudio=off -Denable-coremidi=off -Denable-framework=off \
    -Denable-systemd=off -Denable-portaudio=off >"$WORK.log" 2>&1 || { tail -30 "$WORK.log"; exit 1; }
cmake --build "$WORK" --target libfluidsynth -j 8 >>"$WORK.log" 2>&1 || { tail -30 "$WORK.log"; exit 1; }

mkdir -p "$PREFIX/lib" "$PREFIX/include"
cp "$(find "$WORK" -name 'libfluidsynth.a' | head -1)" "$PREFIX/lib/libfluidsynth.a"
cp "$SRC/include/fluidsynth.h" "$PREFIX/include/" 2>/dev/null || cp "$WORK/include/fluidsynth.h" "$PREFIX/include/"
rm -rf "$PREFIX/include/fluidsynth"
cp -R "$SRC/include/fluidsynth" "$PREFIX/include/fluidsynth"
# 생성된 헤더(version.h 등)
cp "$WORK"/include/fluidsynth/*.h "$PREFIX/include/fluidsynth/" 2>/dev/null || true
[ -f "$WORK/include/fluidsynth.h" ] && cp "$WORK/include/fluidsynth.h" "$PREFIX/include/"
echo "[fluidsynth] 완료: $PREFIX/lib/libfluidsynth.a ($(du -h "$PREFIX/lib/libfluidsynth.a" | cut -f1))"
