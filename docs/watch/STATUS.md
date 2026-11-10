# 애플워치 컨트롤러 — 구현 상태 (2026-11-09, 브랜치 `claude/watch-controller`)

## 화면 디자인 (2026-11-09 확정, `design/watch-board.html` 9차 C-1)

### 10차 (2026-11-09 저녁, 빌드 32 실기기 피드백 → 코드에서 바로 고침, 보드는 9차 그대로)

- **원반 십자키 지름 112 → 140pt.** ABXY 는 64pt 로 키우고 중심을 귀퉁이 쪽으로 2pt 옮긴 뒤, 원반과 겹치는 안쪽 귀퉁이를 **원반 반지름 + 틈 4pt 의 원 곡률대로 깎았다**(`GemShape`, `Path.subtracting`). 글자는 깎인 반대쪽으로 5pt. 사용자 제안("원의 곡률만큼 깎자").
- **크라운 = ◀▶** (앞으로 = ▶), 디텐트 햅틱 켬. 전에는 ▲▼. 좌우는 손가락으로 찾기 어렵고 크라운은 안 보고 돌릴 수 있어서. RPG Maker 메뉴 커서는 ▲▼ 가 주라서 축을 고르는 설정이 필요할 수 있다(미정).
- **(11차, 2026-11-10) 워치 연결 판정과 가상 패드 숨김.** iPhone 은 `TeaSpoonLink.engaged`("워치로 조작 중")로 패드를 숨긴다: 처음 닿거나(reachable) 메시지가 오면(`talking`, 4초) 켜지고, 둘 다 없는 채 **2분**이 지나야 꺼진다 — 손목을 내려 워치가 잠들 때마다 패드가 나왔다 들어가던 흔들림 방지. `isWatchAppInstalled` 는 실기기에서 틀릴 때가 있어 안 본다(패드가 안 숨던 원인으로 추정). 워치 앱이 **백그라운드**(시계·다른 앱으로 나감)로 가면 `.bye`(Event 9)를 보내 iPhone 이 바로 걸쇠를 풀고 패드를 되돌린다; 손목 내림(비활성)은 `releaseAll` 만. 게임을 나가면(홈) 걸쇠 해제. 실기기 결과(2026-11-10 오후): `.bye` 는 sendMessage 만으로는 안 닿고 applicationContext 경로까지 넣은 뒤 닿음 — 그래도 믿지 않고 숨겨진 동안 화면 아래 **"가상 패드 보이기"** 단추(`Spoon/PadRevealButton.swift`)로 손으로 되돌릴 수 있게 함. 시계로 나갔다 오면 watchOS 가 워치 앱을 다시 켜 일련번호가 0 부터 오는데 iPhone 이 중복으로 버리던 문제 → 메시지에 실행 표식 `run`(켤 때마다 무작위) 추가, 바뀌면 번호 기억 초기화. 측정 페이지 맨 위 "판 11차 · 11/10" 으로 어느 워치 앱인지 확인. 사용자: "지금 좋은 거 같아".
- **(11차, 2026-11-10 되돌림) − 는 꾹 누르기(0.25초 넘으면 down…up, 달리기·Shift), + 길게(0.6초) = 일시정지.** 10차의 "−·+ 둘 다 길게 = 일시정지"는 실기기 피드백 "− 를 꾹 눌러 상태를 봐야 하는데 일시정지가 돼 버린다"로 되돌림. 10차 기록: −·+ 둘 다 길게(0.6초) = 일시정지. 실기기에서 `onTapGesture`+`onLongPressGesture` 조합의 길게 누르기가 안 먹어 `GemButton` 처럼 `DragGesture(minimumDistance: 0)` 하나로 바꿈. 0.6초가 되는 순간 ⌂ 를 보내고 `.directionDown` 진동.
- (같은 날 2차 피드백) 틈 4 → **10pt**, 글자는 깎인 만큼 밀지 않고 **사각 때처럼 정가운데**. 크라운은 다시 **▲▼**(올리면 ▲, 내리면 ▼: 값이 느는 쪽 = 목록 아래 스크롤 = ▼. 실기기에서 반대면 부호만 바꾼다). **버튼별 진동** `WatchLink.haptic(for:)`: 원반 `.click` · A `.directionUp` · B `.directionDown` · X `.start` · Y `.stop` · −·+ `.notification` · ⌂ `.success`. 느낌은 실기기에서 고른다.
- (3차 피드백 "답답해 보인다") ABXY **60pt(모서리 22)**, 중심을 원반 중심에서 대각 **±72pt**(32,62 · 176,62 · 32,206 · 176,206)로 4pt 더 바깥. 깎이는 깊이 19 → 약 11pt.
- **iPhone: 워치가 연결되면 가상 패드를 숨긴다.** `watchConnected = 설정 켬 && reachable && watchAppInstalled` 를 실제 컨트롤러와 같은 자리(`anyController`)에 넣음: `padShown`, 일시정지의 "가상 패드 보기"(`padForced`), 일시정지 첫 포커스. 연결되는 순간 `spoon.releaseAll()` + 토스트 "애플워치 연결됨 · 가상 패드 숨김". 워치 앱이 뒤로 가면(reachable false) 패드가 돌아온다. 시뮬레이터 확인: 게임 화면이 컨트롤러 때처럼 가운데로.

보드를 9차까지 돌려 **배치 하나 + 얼음 단색**으로 확정했다. 참고 보고서(ArcEmu · Delta 얼음 스킨 · Pedometer++ Liquid Glass)는 세션 아티팩트로만 남김.
- 208×248pt(46mm) 기준 설계를 화면 비율대로 줄인다(`PadView.design`). 배경은 깊은 남색 라디얼(무늬 없음), 시스템 시계는 그대로 오른쪽 위, 왼쪽 위에 게임 이름 + 연결 점(코랄 = 조작 가능).
- 가운데 **원반 십자키** 지름 112pt(10차에서 140): 네 부채꼴 = 방향, 중립 지름 18pt, 원 밖(+6pt)으로 나가면 뗌. 원 안에서 미끄러지면 방향만 바뀐다(`DiscPad`). 눌린 부채꼴은 하늘색 `#6EC3E8`.
- **ABXY** 60pt 둥근 사각(모서리 24), 원반 가운데에서 대각선 66pt: 왼쪽 위 Y · 오른쪽 위 X · 왼쪽 아래 B · 오른쪽 아래 A(폰 패드 마름모를 45° 돌린 자리). 0.25초 안에 떼면 tap, 넘으면 down→up(`GemButton`).
- **−·+** 14×44pt 세로 알약, 화면 좌우 가장자리(ArcEmu 의 SEL·STA 자리). − 보기 · + 메뉴 · + 길게(0.6초) = 일시정지.
- 재질은 모두 같은 흰 얼음 유리 돔(`Ice.dome`: 위 밝은 그라데이션, 흰 테두리, 위 하이라이트 선, 가장자리 그림자). 지금은 그라데이션으로 그렸고 `glassEffect` 는 안 썼다(시뮬레이터 질감 차이 때문, 실기기에서 비교 뒤 결정).
- 조작 불가(연결 안 됨·설정 끔·홈): 패드 30% 로 흐리고 가운데 세 줄 문구(`WatchLink.statusLabel`). iPhone 앱이 켜질 때 "홈" 컨텍스트를 보내 지난 게임 상태가 남지 않게 함.
- 크라운 ▲▼ 는 덤으로 유지(10차에서 ◀▶ 로). 두 번째 페이지(연결·왕복 측정)는 베타 동안만.
- 시뮬레이터 확인: 홈 상태(흐림 + 문구)와 게임 중(코랄 점, 전체 밝음) 스크린샷 확인. 눌림 표시·쓸어내리기는 실기기에서.


조사(`research.md`) 7장 설계대로 **iPhone 전용 턴제 보조 조작기** 를 시뮬레이터에서 구현·확인했다.
사용자 규칙(2026-11-01): 시뮬레이터 확인까지만, 아카이브·TestFlight 업로드는 하지 않는다. main 에 병합하지 않은 채 둔다.

## 들어간 것

| 자리 | 파일 | 역할 |
|---|---|---|
| 공용 | `BingsuApp/Bingsu/Spoon/TeaSpoonWire.swift` | 메시지 형식(키 `s`·`b`·`e`·`t`, 이벤트 tap/down/up/heartbeat/ping/releaseAll, 앱 컨텍스트 `game`·`state`·`on`). 두 타깃이 같이 컴파일 |
| iPhone | `BingsuApp/Bingsu/Spoon/TeaSpoon.swift` | `TeaSpoonLink`(WCSession 하나, 델리게이트 3종, 설정 상태 문구, 컨텍스트 보내기) + `TeaSpoon`(`LongSpoon` 과 같은 모양: enabled · menuInput · onHomeButton → `SpoonController.press/release`) |
| iPhone | `Bowl/BowlContainerView.swift`, `BrassBowl/BrassBowlContainerView.swift` | `longSpoon` 옆에 `teaSpoon` 생성, 보일 때만 켬, 일시정지 화면이 열리면 `pauseInput` 으로, 게임 이름·상태(playing/paused/home) 컨텍스트 |
| iPhone | `App/BingsuApp.swift` | 앱 시작 때 `TeaSpoonLink.shared.activate()` |
| iPhone | `Kitchen/SettingsView.swift` | 설정 › 컨트롤러 › "애플워치로 조작"(기본 켬, `bingsu.watchController`) + "애플워치" 상태 행. `WCSession.isSupported()` 가 false 인 iPad 에선 안 보임 |
| 워치 | `BingsuApp/BingsuWatch/` | `BingsuWatchApp`(세로 페이지 2장), `WatchLink`(세션·보내기·하트비트·왕복 측정·자가 테스트), `PadView`(십자키·A·B·⧉·≡, 크라운 = ▲▼, ≡ 길게 = ⌂ 일시정지), `StatsView`(연결 상태·왕복 평균/p50/p95/최대·"200회 측정") |
| 프로젝트 | `project.yml` | `BingsuWatch` 타깃(watchOS 26.0, 단일 타깃, `WKApplication`·`WKCompanionAppBundleIdentifier` 를 `info.properties` 에 직접), Bingsu 의존성 → `Bingsu.app/Watch/BingsuWatch.app` |

입력 규칙:
- 탭은 메시지 하나(`tap`): iPhone 이 `press` 뒤 `release`, `SpoonController.minPress`(0.09초) 가 뗌을 붙잡아 게임이 놓치지 않는다.
- 0.25초 넘게 누르면 `down` → 0.3초마다 `heartbeat` → `up`. iPhone 은 하트비트가 1초 끊기면 그 버튼을 놓는다(안 떼짐 방지). 워치 앱이 뒤로 가면 `releaseAll`.
- 일련번호가 뒤로 가거나 같으면 버린다(워치 앱이 다시 켜져 0 부터 시작하면 받아 준다).
- 설정이 꺼져 있으면 받되 버리고 답장 `k=0`. 워치 화면은 컨텍스트 `on=false` 로 "설정에서 꺼져 있어요".
- 워치 쪽 되먹임은 자기 탭의 `.click` 햅틱만. 게임 진동 → 워치 햅틱(P7)은 안 넣었다.

## 시뮬레이터 확인 (2026-11-09)

- 런타임: watchOS 27.2 시뮬레이터(3.9 GB) 내려받음. 워치 시뮬레이터 "Bingsu Watch"(Series 11 46mm) 를 만들어 iPhone 17 Pro(iOS 26.5) 와 짝지음 — **시뮬레이터 두 대 규칙 밖의 세 번째 기기**, 지울지는 사용자 결정.
- 빌드: `xcodebuild -scheme Bingsu` 한 번에 워치 앱까지 들어감(`Bingsu.app/Watch/BingsuWatch.app` 확인). 두 타깃 모두 경고 없이 성공.
- 자가 테스트(`SIMCTL_CHILD_BINGSU_WATCH_SELFTEST=1` 로 워치 앱 실행, iPhone 은 `BINGSU_OPEN=bingsu-sample BINGSU_KEYDEBUG=1`):
  - 워치가 켜지자 컨텍스트로 `상태=playing 게임=Bingsu` 를 바로 받음.
  - 왕복 41회(120초 제한에 걸림): **평균 2.9초, p50 3.0초, p95 4.8초, 최대 5.1초, 오류 0** — 시뮬레이터 WC 값이라 참고만(연구 8.2 ⑦). 실기기 판단선(p95 ≤ 300ms)은 P3 에서 잰다.
  - 버튼 열: A 탭 → ▶ 누르고 있기(down·heartbeat×2·up) → B 탭 → ⌂ → ▼ → B. iPhone 로그에 같은 순서로 도착, ⌂ 뒤의 ▼·B 는 `menu=true`(일시정지 화면 조작)로 처리, B 로 닫힘. 게임은 A 로 시작돼 진행 중(스크린샷).
  - 같은 조건의 자가 테스트는 이제 30회만 잰다(시뮬레이터가 한 번에 2~3초).

## 남은 것 (사용자 결정 뒤)

1. **P3 실기기 지연** — iPhone + 사용자 워치에서 StatsView "200회 측정": 손목 듦 / 내림 / 컨트롤러·이어폰 연결 중 / Wi-Fi 끔 / 연타. 실기기 빌드는 워치 App ID(`com.minwoo.bingsu.watchkitapp`)를 자동 서명이 만들어야 한다(연구 6.2).
2. P5 누르고 있기 끊김 수, P6 크라운 칸 수 일치율 — 실기기에서.
3. P7 되먹임(게임 진동 → 워치 햅틱, 기본 끔) — 지연이 쓸 만할 때만.
4. TestFlight 에 넣으려면: 워치 스크린샷(필수), 워치 아이콘은 iOS 1024 를 그대로 씀(심사 2.3.8 은 비슷하면 됨), `THIRD_PARTY_LICENSES.md` 변화 없음(새 라이브러리 없음).
5. 알려진 한계: iPad 불가(WC 미지원), 워치 앱이 앞에 있어야 함, 실시간 조작은 기대하지 않음.
