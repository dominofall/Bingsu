# rgss-check — RPG Maker 게임 Ruby 버전별 시작 점검

RPG Maker XP·VX·VX Ace 게임(놋그릇 = mkxp-z 포크)을 **Ruby 프로필(18·19·31)별로 시뮬레이터에서 시작 화면까지 자동으로 띄워**
스크립트 오류·엔진 해상도·게임이 밝힌 화면 크기와의 불일치·스크린숏을 표로 남긴다.
목적: 포켓몬 Z(한글 패치)의 "화면이 왼쪽 위로 치우침"(Ruby 3.1 에서 맨 위 def 가 비공개라 `Kernel.respond_to?` 가 거짓)
같은 **Ruby 버전 차이 문제를 사용자보다 먼저 찾기**.

빙수는 게임 폴더에 `mkxp.json`(또는 `x64-msvcrt-ruby3*.dll`)이 있으면 Ruby 3.1, 아니면 XP·VX 는 1.8, VX Ace 는 1.9 로 돌린다
(`RubyProfile.detect`). 이 도구는 그 자동값과 18·31(VX Ace 면 19 도)을 `BINGSU_RUBY` 로 바꿔 가며 띄운다.

## 파일

| 파일 | 하는 일 |
|---|---|
| `rgss-check.sh` | 실행기. 게임 목록 → 복제본 준비 → 프로필마다 앱을 새로 띄워 기다림 → 스크린숏·로그 모음 → `report.md` |
| `scan.rb` | 게임 폴더만 읽어서: RGSS 판, 자동 Ruby, 게임이 밝힌 화면 크기(mkxp.json, `DEFAULTSCREENWIDTH/HEIGHT`, Settings `SCREEN_WIDTH/HEIGHT`), Ruby 버전 차이 위험 코드(정적 검색) |
| `probe.rb` | 복제본의 mkxp.json `preloadScript` 에만 붙는 측정 스크립트. 엔진 로그에 실제 `Graphics.width/height`, `resize_screen` 호출, 맨 위 def 공개 여부를 남긴다 |
| `report.rb` | 결과 폴더(들) → markdown 표. 폴더를 여러 개 주면(고친 빌드·고치기 전 빌드) 한 표에 나란히 |

## 쓰는 법

```bash
# 1) 디버그 빌드 (시뮬레이터). 다른 브랜치 코드로 만들려면 git archive 로 임시 폴더에 풀어서 거기서 빌드한다
#    (엔진 프레임워크는 BingsuApp/build/BrassBowl 을 심볼릭 링크로, THIRD_PARTY_LICENSES.md 도 함께 풀 것)
# 2) 점검 — 다른 세션이 쓰지 않는 시뮬레이터 하나만
tools/rgss-check/rgss-check.sh -d <UDID> -a <Bingsu.app> -l fix
# 게임을 직접 고를 때 (기본 목록 없이)
tools/rgss-check/rgss-check.sh -d <UDID> -l fix --only "<게임 폴더>" "<게임 폴더>"
# 두 빌드 결과를 한 표로
ruby tools/rgss-check/report.rb <결과1> <결과2> > report.md
```

| 옵션 | 기본 | 뜻 |
|---|---|---|
| `-d UDID` | (필수) | 시뮬레이터 |
| `-a 앱` | 없음 | 주면 먼저 `simctl install` (같은 번들 id 라 깔려 있던 빌드를 덮는다) |
| `-l 이름` | `build` | 표의 "빌드" 칸 (예: `fix`, `base`) |
| `-p "auto 18 31"` | 그대로 | 프로필. `auto` 는 자동 판별값으로 바뀌고 같은 값은 한 번만. VX Ace 게임은 19 를 덧붙임 |
| `--t1 20 --t2 34` | | 첫·둘째 스크린숏 시각(실행 뒤 초) |
| `--keys "24:KeyC,27:KeyC"` | | `BINGSU_KEYS` — 게임 화면이 뜬 뒤 그 시각에 확인 키 (타이틀 다음 화면까지). 빈 값이면 안 누름 |
| `--work 폴더` | `$TMPDIR/rgss-check-work` | zip 해제·복제본·결과 위치 |
| `-o 폴더` | `<work>/results/<시각>-<이름>` | 결과 폴더 |
| `--no-probe` | | probe.rb 를 넣지 않음 (실제 화면 크기 칸이 빈다) |
| `--only` | | 기본 게임 목록을 쓰지 않음 |
| `--clean` | | 끝나면 게임 옆에 만든 `.rgss-check-stage/` 를 지움 |
| `--stage 폴더` | | 원본과 같은 볼륨의 복제본 자리 (게임 옆 숨김 폴더 대신. 예: `~/Dev/.rgss-check-stage`) |
| `-e 키=값` | | 앱에 넘길 환경변수 더하기 (여러 번). 예: `-e BINGSU_NO_TOPLEVEL=1` 로 맨 위 def 공개 스크립트를 빼 예전 증상 재현 |
| `--local` | | WORK 와 다른 볼륨의 게임은 WORK 로 진짜 복사해 돌리고 바로 지운다 (느린 외장 디스크용, 여유 공간 확인) |

**기본 게임 목록**: 저장소 맨 위 폴더 중 RPG Maker 게임(Game.ini + Scripts.*data 또는 Game.rgss*), `Games/*/`·`Games/*/*/` 의 RPG Maker 게임,
`Games/*/*/*.zip`(RTP zip 제외)을 `<work>/unzipped/` 에 풀어서.

## 어떻게 띄우나

- 게임마다 **APFS 복제본**(`cp -c`, 공간을 거의 안 씀)을 `<work>/stage/<id>/<id>` 에 만든다. 원본과 볼륨이 달라 복제가 안 되면
  게임 옆 `.rgss-check-stage/<id>/<id>` 에 만든다(저장소 맨 위 게임이 이 경우 — 끝나면 `--clean` 으로 지울 것). `cp -c` 는 볼륨이 다르면
  말없이 진짜 복사를 하므로 장치 번호를 먼저 확인한다(내장 디스크 여유가 적음).
- 복제본 mkxp.json 의 `preloadScript` 에 probe.rb 를 붙인다(빙수가 자기 스크립트를 그 뒤에 덧붙임 — Ruby 3.1 맨 위 def 공개 스크립트는 맨 앞).
  **mkxp.json 이 없는 게임에는 넣지 않는다** — 넣으면 빙수 자동 판별이 Ruby 3.1 로 바뀐다.
- 앱은 `BINGSU_DEV_GAMES` 폴더 안 게임을 모두 훑으므로 게임마다 상위 폴더를 따로 둔다. 디쉬 id = 폴더 이름.
- 실행마다 앱을 끄고 새로 띄운다(Ruby VM 은 한 프로세스에서 다시 시작할 수 없음):
  `SIMCTL_CHILD_BINGSU_DEV_GAMES / _OPEN / _RUBY / _MKXP_LOG=1 / _FORCE_PAD=1 / _KEYS` + `xcrun simctl launch`.
- 모으는 것: 앱 로그(`[BrassBowl]` — `시작 … ruby=`, `엔진 오류:`, `게임 화면 비율`, `엔진 끝남`), 앱 데이터 `tmp/brassbowl.log`
  (`scRes=`, `[RUBY]`, `[rgss-check]` 줄), 스크린숏 2장.

**느린 디스크**: 엔진은 시작할 때 게임 파일을 모두 훑는다(`createPathCache`). `~/Dev` 디스크 이미지에 있는 2만 개짜리
Essentials 게임은 이것만 몇 분이 걸려 90초 안에 Ruby 가 시작되지 않았다("여는 중"). 그런 게임은 `--local` 로 내장 디스크에 복사해 돌린다.

엔진(mkxp-z 포크)은 `Graphics.resize_screen` 을 로그에 남기지 않는다. 그래서 실제 화면 크기는 probe.rb 로 잰다.

## 결과 읽기

`report.md` 의 표: 게임 × 빌드 × Ruby 프로필.
- **시작**: ✓(게임 화면 신호) / 오류로 멈춤 / 끝남 / 엔진만 / ✗
- **엔진 해상도 → 실제 화면**: `scRes`(엔진이 연 크기) → probe 가 마지막으로 본 `Graphics.width x height`
- **게임이 밝힌 크기·일치**: 스크립트 값과 실제 화면이 다르면 ✗ (포켓몬 Z 증상: 640x480 인데 게임은 512x384 로 그림)
- **맨 위 def 공개**: probe 가 맨 위에 만든 함수에 `Kernel.respond_to?` 한 값. RGSS 와 같으면 true
- 아래에 게임마다 **Ruby 버전 차이 위험 코드** 목록(정적 검색이라 거짓 양성 있음, high 부터 볼 것)

## 주의

- 시뮬레이터는 다른 세션과 같이 쓴다. 쓰기 전에 어느 기기가 비었는지 확인하고, 그 기기만 `-d` 로 준다. `-a` 는 깔린 빌드를 덮는다.
- 게임이 저장 데이터 폴더(`Documents/Saves/<dataPathApp>`)에 옵션 파일 등을 쓸 수 있다. 시작 화면까지만 가므로 보통은 없다.
- 결과 폴더(스크린숏·로그)에는 게임 화면이 들어 있으니 커밋하지 않는다. 기본 위치는 저장소 밖(`$TMPDIR`).
- 암호화 아카이브(`Game.rgss2a/3a`) 게임은 스크립트를 못 읽어 정적 검사·밝힌 크기 칸이 빈다(🔒).
