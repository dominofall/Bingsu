# 놋그릇 (BrassBowl) — RPG Maker XP 엔진

RPG Maker XP 게임은 [mkxp-z-apple-mobile](https://github.com/mateo-m/mkxp-z-apple-mobile)(mkxp-z 의 iOS 포크, GPL-3.0 + 추가 조건)을 하나의 동적 프레임워크 `BrassBowl.framework` 로 묶어 돌린다.

- 빙수 본체는 엔진을 링크하지 않는다. 게임을 열 때 `Bingsu/BrassBowl/BrassBowlEngine.swift` 가 `Frameworks/BrassBowl.framework/BrassBowl` 을 `dlopen` 하고 `mkxp_*` 함수만 `dlsym` 으로 부른다.
- 최소 iOS 는 26 이다. 포크 기본값 그대로이고, 빙수 앱도 26 으로 맞췄다(2026-10-30). 포크는 26 전용 API 를 쓰지 않아서 나중에 내려야 하면 `MINIMUM_REQUIRED=17.0` 처럼 make 변수만 덮어써 빌드할 수 있다(아래 절).
- 프레임워크가 없으면(엔진을 안 만든 환경) 앱은 그대로 빌드되고 RPG Maker XP 게임만 "준비 중"으로 보인다.
- 엔진 바이너리·소스·게임 파일은 저장소에 넣지 않는다. 결과물은 `BingsuApp/build/BrassBowl/<sdk>/` (gitignore).

## 만드는 순서

엔진 소스는 저장소 밖 `~/Dev/vendor/mkxp-z-apple-mobile` (다른 곳이면 `MKXP_SRC=`)에 둔다. 빙수에 넣은 판은 태그 v9, 커밋 `68efcd3` 이고 소스는 고치지 않는다.

```bash
git clone https://github.com/mateo-m/mkxp-z-apple-mobile ~/Dev/vendor/mkxp-z-apple-mobile && git -C ~/Dev/vendor/mkxp-z-apple-mobile checkout 68efcd3
```

포크는 하위 모듈(hmode7·openal-soft·sdl2 등)을 쓴다. 하위 모듈 주소가 `git@github.com:` 이라 GitHub SSH 키가 없으면 https 로 바꿔 받는다.

```bash
git -C ~/Dev/vendor/mkxp-z-apple-mobile -c url."https://github.com/".insteadOf=git@github.com: submodule update --init --depth 1
```

MIDI 합성기 FluidSynth 소스도 받아 둔다 (아래 "소리" 절, 다른 곳이면 `FLUID_SRC=`).

```bash
git clone --depth 1 --branch v2.5.7 https://github.com/FluidSynth/fluidsynth ~/Dev/vendor/fluidsynth
```

아래 명령에서 `BingsuApp/...` 으로 시작하는 것은 빙수 저장소 맨 위 폴더에서, `cd ~/Dev/vendor/...` 로 시작하는 것은 그 자리에서 실행한다.

1. 의존성과 엔진 코어 (SDK 마다, 처음엔 한 시간 가까이 걸린다). 포크 README 는 Homebrew 의 automake·autoconf·libtool·cmake·pkg-config·bison 을 요구한다. bison 은 macOS 기본 `/usr/bin/bison`(2.3)으로도 빌드됐다.

   ```bash
   cd ~/Dev/vendor/mkxp-z-apple-mobile && tools/build-deps-ios.sh iphonesimulator && make -C deps -f iphonesimulator.make mkxp-merged
   ```

   그다음 MIDI 합성기(아래 "소리" 절)를 만들고 코어를 `SHARED_FLUID` 로 빌드한다.

   ```bash
   sh BingsuApp/BrassBowl/build-fluidsynth.sh iphonesimulator
   ```

   ```bash
   cd ~/Dev/vendor/mkxp-z-apple-mobile/deps && rm -rf build-iphonesimulator-arm64/core-obj build-iphonesimulator-arm64/lib/libmkxpz-core.a && EXTRA_CORE_CFLAGS="-DSHARED_FLUID" make -f iphonesimulator.make mkxp-core
   ```

   코어는 파일 수정 시각으로만 다시 컴파일하므로, 플래그를 바꿀 때는 위처럼 `core-obj` 를 지우고 빌드한다. 실기기용은 `iphonesimulator` 를 `iphoneos` 로 바꿔 한 번 더.

   Ruby 1.9 `process.c` 에서 `'system' is unavailable` 로 멈추면 Ruby 소스 트리(`deps/sources/ruby*`)의 포크 패치가 풀린 것이다. `build-deps-ios.sh` 가 `configure` 를 먼저 건드려 패치 규칙이 다시 돌지 않으므로, `configure.in`(3.1 은 `configure.ac`)을 `touch` 한 뒤 `make -C deps -f <sdk>.make "$PWD/deps/sources/ruby19/configure"` 처럼 그 규칙을 직접 부른다(ruby·ruby18·ruby19).

2. 프레임워크 링크 (몇십 초)

   ```bash
   sh BingsuApp/BrassBowl/build-framework.sh iphonesimulator
   ```

   `deps/build-<sdk>-arm64/` 의 정적 라이브러리·ANGLE·셰이더·글꼴·Ruby 표준 라이브러리를 묶어 `build/BrassBowl/<sdk>/BrassBowl.framework` (약 38MB)를 만든다. 내보내는 이름은 `brassbowl.exports` 의 `_mkxp_*` 뿐이다. 딸린 라이브러리 라이선스(`licenses.json`)는 포크 목록에 `extra-licenses.json`(ANGLE·libpng·FluidSynth)을 더해 넣고, 앱 "오픈소스 라이선스" 화면이 그대로 읽는다.

3. 앱 빌드. `project.yml` 의 빌드 후 스크립트 "BrassBowl 넣기"(`embed-framework.sh`)가 지금 플랫폼에 맞는 프레임워크를 `Bingsu.app/Frameworks/` 에 복사하고 서명한다. 스크립트를 바꿨으면 `xcodegen generate`.

다 만든 뒤 디스크가 모자라면 `deps/downloads`(1.4GB 안팎)는 지워도 된다(다시 빌드할 때 다시 받는다).

## 소리 — MIDI (FluidSynth)

포크에는 MIDI 합성기 FluidSynth 가 없다. 그대로 두면 엔진이 실행 중 `@rpath/libfluidsynth.dylib` 를 찾다가 못 찾고 MIDI 를 건너뛰어, MIDI BGM 을 쓰는 게임이 무음이 된다. 그래서 FluidSynth 를 프레임워크 안에 정적으로 넣는다.

1. `build-fluidsynth.sh <sdk>` — FluidSynth 2.5.7(LGPL-2.1, 소스는 `~/Dev/vendor/fluidsynth`, 태그 v2.5.7, 고치지 않음)을 glib 없이(`osal=cpp11`), 오디오 드라이버·네트워크 없이 iOS 정적 라이브러리(약 700KB)로 빌드해 `deps/build-<sdk>-arm64/{lib,include}` 에 넣는다. iOS 에서는 CMake 가 `fluidsynth` 명령을 번들로 만들어 install 이 깨지므로 `CMAKE_MACOSX_BUNDLE=OFF` 를 준다.
2. 코어를 `EXTRA_CORE_CFLAGS="-DSHARED_FLUID"` 로 다시 빌드하면 엔진이 dylib 를 찾는 대신 `fluid_*` 를 직접 부른다(`src/audio/fluid-fun.cpp`).
3. `build-framework.sh` 는 `libfluidsynth.a` 가 있으면 같이 링크한다.

사운드폰트는 게임의 `mkxp.json` 의 `midiSoundFont`(게임에 든 `.sf2`)를 쓴다. 엔진의 오디오 스레드가 `MidiSource::fillBuffer` → `fluid_synth_write_s` 로 합성한다.

## 최소 iOS 를 내리려면

포크 파일은 그대로 두고 make 변수만 덮어쓴다. 처음 빌드한 판과 다르면 먼저 `make -C deps -f <sdk>.make clean-sources` 로 configure 결과를 지우고 `deps/build-<sdk>-arm64` 를 치운다.

```bash
cd ~/Dev/vendor/mkxp-z-apple-mobile && MAKEFLAGS="MINIMUM_REQUIRED=17.0" tools/build-deps-ios.sh iphonesimulator && make -C deps -f iphonesimulator.make mkxp-merged mkxp-core MINIMUM_REQUIRED=17.0
```

그다음 `build-framework.sh` 의 `MIN_OS` 와 `project.yml` 의 `deploymentTarget` 을 같이 내린다. iOS 쪽 엔진 코드(5개 파일)는 iOS 13 때부터 있던 API 만 쓰고, ANGLE 미리 빌드본은 16 이상이라 17 까지는 될 것으로 보이지만 실제로 돌려 본 적은 없다.

## 디버그

| 환경변수 | 동작 |
|---|---|
| `BINGSU_MKXP_LOG=1` | 엔진 디버그 로그 |
| `BINGSU_KEYS="초:코드,…"` | 그 시각마다 키 한 번 (예: `8:KeyC,10:KeyC`) |
| `BINGSU_AUTOKEY="코드:간격:횟수"` | 12초 뒤부터 그 키를 반복 |
| `BINGSU_FORCE_PAD=1` | 컨트롤러가 붙어 있다고 나와도(시뮬레이터) 가상 패드 표시 |

시뮬레이터에서는 `SIMCTL_CHILD_` 를 붙여 넘긴다. 로그: `xcrun simctl spawn <UDID> log show --last 2m --style compact | grep "BrassBowl\|IceTray"`.

## 한계

- Ruby VM 은 프로세스마다 한 번만 띄울 수 있다. RPG Maker XP 게임을 한 번 끝내면 빙수를 다시 열어야 다시 할 수 있다(앱이 안내한다). 다른 게임으로 넘어가려 하면 끝낼지 먼저 묻는다.
- 저장은 게임 안 메뉴로만 한다. 저장 파일은 PC 와 똑같이 `Documents/Saves/<dataPathApp>/` 에 쓰이고, `IceTray` 가 save.json 으로 묶어 백업·iCloud 에 태운다.
