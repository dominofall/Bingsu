# 포켓몬 게임 진동 1차 표

작성 2026-11-19 (빌드 51, 브랜치 `rumble-51`). **빌드 51 기본값으로 채택**(사용자 2026-11-19, 아이폰에서 시험 게임 `tools/rumble-table` 로 확인 후 "일단 이렇게 기본으로 넣고 점차 수정"). 세기 숫자는 이후 빌드에서 조금씩 고친다. 이 표가 기준이고, 게임별 JSON(`BingsuApp/Bingsu/Resources/Rumble/`)은 이 표의 "상황"에 그 게임의 효과음 이름을 붙이기만 한다.
진동 세기·길이는 상황마다 한 곳(`events.json`)에서만 정한다. 게임 파일에 숫자를 따로 쓰는 일은 피한다.

세기는 0~1. "묵직"은 저주파 모터(strong), "가벼움"은 고주파 모터(weak). 길이는 초.

## 1. 상황 → 진동

### 전투: 맞고 쓰러짐

| 상황 (`event`) | 언제 | 묵직 | 가벼움 | 길이 | 느낌 | 1차 |
|---|---|---|---|---|---|---|
| `hit_weak` | 효과가 별로인 공격을 맞음 | 0.25 | 0.3 | 0.10 | 톡 | 켬 |
| `hit_normal` | 보통 공격을 맞음 | 0.6 | 0.4 | 0.16 | 퍽 | 켬 |
| `hit_super` | 효과가 굉장한 공격을 맞음 | 1.0 | 0.6 | 0.28 | 쿵 (표에서 가장 셈) | 켬 |
| `faint` | 포켓몬이 쓰러짐 | 0.8 | 0.2 | 0.45 | 길고 낮게 쿠웅 | 켬 |

### 전투: 몬스터볼

| 상황 | 언제 | 묵직 | 가벼움 | 길이 | 느낌 | 1차 |
|---|---|---|---|---|---|---|
| `ball_throw` | 볼을 던짐 | 0.2 | 0.5 | 0.10 | 휙 | 켬 |
| `crit_throw` | 크리티컬 캡처로 던짐 | 0.5 | 0.7 | 0.14 | 휙 (조금 셈) | 켬 |
| `ball_hit` | 볼이 포켓몬에 맞음 | 0.5 | 0.3 | 0.08 | 탁 | 켬 |
| `catch_absorb` **(새)** | 포켓몬이 볼에 빨려 들어감 | 0.35 | 0.4 | 0.12 | 슉 | 켬 |
| `ball_drop` | 볼이 땅에 떨어짐 | 0.3 | 0.3 | 0.08 | 톡 | 켬 |
| `ball_shake` | 볼이 한 번 흔들림 (게임이 흔들 때마다 소리) | 0.45 | 0.2 | 0.12 | 덜컥 ×흔들린 수 | 켬 |
| `catch_click` | 포획 확정 (딸깍) | 0.7 | 0.5 | 0.30 | 딸깍 + 여운 | 켬 |
| `recall` | 볼이 열림: 내보내기·돌아오기 | 0.2 | 0.4 | 0.10 | 가볍게 툭 | 켬 |

### 전투: 그 밖

| 상황 | 언제 | 묵직 | 가벼움 | 길이 | 느낌 | 1차 |
|---|---|---|---|---|---|---|
| `flee` | 도망침 | 0.3 | 0.3 | 0.18 | 스륵 | 켬 |
| `level_up` | 레벨 업 | 0.2 | 0.5 | 0.20 | 가볍게 반짝 | 켬 |

### 화면 흔들림 (효과음과 별개)

| 상황 | 언제 | 세기 | 길이 | 1차 |
|---|---|---|---|---|
| `shake` | 게임이 화면을 흔듦 (RPG Maker `start_shake`·`startShake`) | power÷9 (묵직), 그 반 (가벼움) | 프레임÷40초, 0.08~0.5초 | 켬, 게임 표 `"shake": false` 로 끔 |

효과음 진동과 흔들림이 0.15초 안에 겹치면 센 쪽 하나만 울린다.

### 넣지 않는 것 (1차)

| 소리 | 왜 |
|---|---|
| 울음소리, 메뉴(커서·결정·취소), 기술 효과음(`prsfx- …`), 능력치 올림·내림, 경험치 오르는 소리 | 너무 잦거나 길어서 손이 피곤함. 시뮬레이터 전투에서 실제로 1초에 여러 번 남 |
| 필드: 벽에 부딪힘(`player bump`), 턱 뛰어내림(`player jump`), 독 걸음(`poison step`) | 느낌은 좋을 수 있지만 걸을 때마다 남. **2차 후보** (실기기로 느껴 보고 결정) |
| 배지·아이템 얻음, 진화, 알 (포켓로그 `egg_crack`·`egg_hatch` 는 지금 표에 있어 유지) | 대부분 ME(긴 음악)라 진동과 박자가 안 맞음. 2차 후보 |

## 2. 게임별 효과음 이름

빈칸(—)은 그 게임에 맞는 소리가 없거나 아직 못 찾은 것. ✅ 는 시뮬레이터 전투에서 실제로 울린 것(2026-11-19).

| 상황 | 어나더레드 (신형 Essentials) | 포켓몬 Z (구형 Essentials) | 레조넌스 (웹) | 포켓로그 (웹) |
|---|---|---|---|---|
| `hit_weak` | `battle damage weak` ✅ | `notverydamage` | `hit_weak` | `hit_weak` |
| `hit_normal` | `battle damage normal` ✅ | `normaldamage` ✅ | `hit` | `hit` |
| `hit_super` | `battle damage super` | `superdamage` | `hit_strong` | `hit_strong` |
| `faint` | `pkmn faint` ✅ | `faint` ✅ | `faint` | `faint` |
| `ball_throw` | `battle throw` | `throw` | `battle throw`·`pb_throw` | `pb_throw` |
| `crit_throw` | `battle critical catch throw` | — | — | `crit_throw` |
| `ball_hit` | `battle ball hit` | — | `battle ball hit` | `pb_bounce_1`·`pb_bounce_2` |
| `catch_absorb` | `battle jump to ball` | `jumptoball` | `battle jump to ball` | — (`pb_rel` 은 튀어나올 때도 나서 보류) |
| `ball_drop` | `battle ball drop` | `balldrop` | `battle ball drop` | — |
| `ball_shake` | `battle ball shake` | `ballshake` | `battle ball shake` | `pb_move` |
| `catch_click` | `battle catch click` | — | `battle catch click` | `pb_catch` |
| `recall` | `battle recall` | `recall` ✅ (내보낼 때) | `battle recall` | — |
| `flee` | `battle flee` | `flee` | — | `flee` |
| `level_up` | `pkmn level up` | `expfull` | — (`level_up_fanfare` 확인 필요) | `level_up` |
| 따로 | — | — | — | `pb_lock` (0.3·0.6·0.1), `egg_crack`, `egg_hatch` |

## 3. 표가 들어 있는 곳

| 파일 | 담는 것 |
|---|---|
| `events.json` | 위 1절의 상황별 세기·길이 (한 곳에서만 고친다) |
| `base-essentials.json` | 신형 Essentials 이름 (어나더레드·레조넌스 열). 게임 표가 없는 게임에도 씀 |
| `base-essentials-classic.json` | 구형 Essentials 이름 중 다른 게임과 헷갈리지 않는 것 (`normaldamage`·`jumptoball` 등) |
| `base-pokerogue.json` | 포켓로그만의 이름 (`pb_*`, `crit_throw`) |
| `pokemon-z.json` | `throw`·`faint`·`recall`·`flee` 처럼 흔한 단어라 기본 표에 둘 수 없는 Z 이름 |
| `another-red.json`·`resonance.json`·`pokerogue.json` | 기본 표를 물려받고, 그 게임만의 이름만 |

흔한 단어(`throw`, `faint`, `hit`, `flee`)는 포켓몬이 아닌 RPG Maker 게임에도 있을 수 있어서 **기본 표에 넣지 않고** 게임 표에만 둔다. 기본 표는 게임 표가 없는 모든 게임에 쓰이기 때문이다.

## 4. 아직 확인할 것

- 효과 굉장함·포획(던지기~딸깍)·레벨 업은 시뮬레이터에서 아직 못 울려 봄. 실기기에서 직접 잡아 보며 확인.
- Z 의 포획 확정 소리(아마 ME)와 볼이 맞는 소리, 레조넌스의 도망·레벨 업 소리 이름.
- 포켓로그 `pb_rel`·`pb_lock`·`pb_catch` 의 정확한 순간 (`attempt-capture-phase` 소스 다시 보기).
- 세기 숫자는 IINE 스위치 모드 컨트롤러·iPhone 에서 직접 느껴 보고 고친다 (짧은 진동은 0.2초 아래면 잘 안 느껴진다는 기록 있음, `Rumble.minLength`).
