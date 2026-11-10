# iPhone 을 iPad 컨트롤러로 — 구현 상태 (2026-11-09)

조건은 `CONDITIONS.md`. 코드 이름 **TableSpoon**(워치 TeaSpoon 과 짝). 시뮬레이터에서 화면·입력 경로까지 확인했고, 기기 사이 연결은 실기기 몫.

## 들어간 것

| 어디 | 파일 | 무엇 |
|---|---|---|
| 공통 형식 | `Spoon/TeaSpoonWire.swift` | 이벤트 `rumble(6)`·`context(7)`, 진동 키, `encode/decode`(바이너리 plist, 4KB 상한). 워치 타깃도 같이 컴파일(새 이벤트는 무시) |
| 연결 | `Spoon/TableSpoon.swift` | `TableSpoonLink`(iPad: MultipeerConnectivity 광고·수락·받기·컨텍스트·진동 보내기, 설정 키 `bingsu.tableSpoon` 기본 켬) · `TableSpoonRemote`(iPhone: 찾기·초대·tap/down/up/하트비트·releaseAll·100회 ping 측정·진동 받기). 암호화 `.required`. 순번으로 중복·역순 버림 |
| 받는 길 | `Spoon/TeaSpoon.swift` | `TeaSpoon` 이 워치 링크와 iPhone 링크 둘 다에 `target` 으로 등록. `TeaSpoonLink.setContext` 가 iPad → iPhone 컨텍스트도 같이 보냄 |
| 배치 | `Spoon/TableSpoonLayout.swift` | `SpoonLayout.makeController`: 393pt 기준 × 기기 비율 k(0.9…1.15) × 사용자 크기. 십자키 r84 왼쪽 아래(떠다니기면 왼쪽 46% 영역), ABXY r34·간격 60 오른쪽 아래 + `snapRadius`, L·R 위 모서리 큰 알약, −·+ 위 가운데 |
| 패드 공통 | `Spoon/SpoonModel.swift`, `SpoonTouchView.swift`, `SpoonController.swift` | `SpoonLayout.dpadZone`(떠다니는 십자키 영역)·`snapRadius`(빈 곳 → 가장 가까운 둥근 버튼), 터치 뷰의 `.dpadFloat` 대상(댄 자리가 중심, 반지름 1/5 벗어나면 방향, 바깥 한계 없음), `SpoonController.dpadFloatCenter`(그리기용). 기존 배치는 둘 다 꺼져 있어 영향 없음 |
| iPhone 화면 | `Spoon/TableSpoonView.swift` | 홈 툴바 게임패드 단추(iPhone 만) → 전체 화면. 가로 잠금(`AppDelegate.lockOrientation`), 화면 꺼짐 방지, 연결 전 iPad 목록, 연결 후 `SpoonFace`+`SpoonTouchView`(전역 스킨), 가운데 상태(iPad 이름·게임·왕복), 아래 가운데 설정(떠다니는 십자키·크기·100회 측정)·닫기. 눌림 변화 → `down/up`, 묶음별 진동(십자키 light · ABXY medium · L/R rigid · −+ soft) |
| iPad 쪽 | `MenuBoard/MenuBoardView.swift`, `Bowl/…`, `BrassBowl/…`, `Kitchen/SettingsView.swift`, `Spoon/Rumble.swift`, `App/BingsuApp.swift` | 초대 알림("연결/거절", 게임 중에도), `anyController` 에 `tableConnected` → 가상 패드 숨김 + 토스트, 설정 › 컨트롤러 › "iPhone 을 컨트롤러로" + 상태, 게임 진동을 iPhone 으로 전달(`forwardRumble`, 보냈으면 iPad 는 안 울림), 앱 시작 때 `TableSpoonLink.start()` |
| Info.plist | `project.yml` | `NSBonjourServices` `_bingsu-pad._tcp/_udp`, `NSLocalNetworkUsageDescription` 문구에 컨트롤러 추가 |

## 배치 종류 (2026-11-10 추가, 사용자 "엑박 같은 다른 컨트롤러 조작들도")

설정 `tableSpoon.kind`(`TableSpoonKind`): **기본(십자키)** = 전용 배치 · **스틱** · **Xbox 전체** · **레트로**. 뒤의 셋은 게임 패드 배치(`SpoonLayout.make`)를 1.25배로 그린 것이고, 어느 종류든 ABXY 사이 빈 곳은 가장 가까운 버튼(`snapRadius`). 스틱은 늘 떠다니기.
- **스틱 전송**: `TeaWire.Event.stick(8)` + `lx ly rx ry`. iPhone 은 30Hz 로 모아 바뀔 때 보내고(0.02 단위 반올림), 기울어 있는 동안 0.3초마다 한 번은 보낸다. 가운데로 돌아오는 메시지만 reliable. iPad `TeaSpoon.handleStick` → `SpoonController.setStick`, 1초 동안 값이 안 오면 가운데로(`stickAt`), 끊기면 즉시 가운데로.
- loopback 자가 테스트에 스틱 ▶ 0.7초가 들어감: `스틱 L(1.00,0.00)` 세 번(처음 + 하트비트 둘) 뒤 `L(0.00,0.00)` 도착 확인.
- 가운데 글 아래에 설정·닫기 단추(−·+ 가 아래 가운데인 배치가 있어서).

## 세로 배치 (2026-11-10 추가, 사용자 "세로형 키배열도")

가로 잠금을 풀고 기기 방향을 따른다(`AppDelegate.lockOrientation` 은 남겨 두되 부르지 않음). 세로면 게임 패드의 세로 배치(`makePortrait`, 폭에 맞춰 자동 축소)를 1.3배로, "기본"은 세로 기본 배치 + 십자키 쪽 절반에 떠다니는 십자키 영역. 종류에 **한손(세로)** 추가(`makeOneHand`, 쓰는 손 설정 `tableSpoon.leftHanded`; 가로로 돌리면 기본). 가운데 글·단추는 세로에서 패드 위 빈 자리 가운데(`layout.topEdge`). 시뮬레이터 스크린샷: 기본·한손·Xbox 전체 세로.

## 확인한 것 (시뮬레이터, 2026-11-09)

- 빌드: iPhone·워치 타깃 모두 성공.
- **시뮬레이터 둘(iPhone 17 Pro ↔ Pro Max) 사이 MultipeerConnectivity: 찾기까지만 된다.** 리모트가 "iPhone 17 Pro Max" 를 찾고 초대 Hello 를 보냈지만 호스트에 초대가 닿지 않아 20초 뒤 타임아웃. 같은 Mac 의 시뮬레이터 둘 사이 MC 의 알려진 한계로 본다 → 연결은 실기기로.
- **loopback 자가 테스트**(개발용 `BINGSU_TABLESPOON_LOOPBACK=1`, 한 시뮬레이터에서 보내는 쪽 → 바이트 인코딩 → 받는 쪽): A 탭 → ▶ down·하트비트 2번·up → B 탭이 iPad 쪽 `TeaSpoon` 에 같은 순서로 도착(`[TeaSpoon] 받음` 로그), ping 30회 답장 수신. 컨텍스트(게임 이름 "Bingsu", playing)도 iPhone 화면에 표시됨.
- 화면: 가로 잠금으로 패드가 그려짐(시뮬레이터는 기기를 돌리지 않아 세로 틀 안에 가로 내용). 스크린샷은 세션 기록.
- 개발용 환경 변수: `BINGSU_TABLESPOON_HOST=1`(iPhone 도 받는 쪽), `BINGSU_TABLESPOON_AUTOACCEPT=1`(물음 없이 수락), `BINGSU_TABLESPOON=1`(켜자마자 컨트롤러 화면, 첫 iPad 에 자동 연결), `BINGSU_TABLESPOON_SELFTEST=1`(버튼 순서 + 30회 측정), `BINGSU_TABLESPOON_LOOPBACK=1`.

## 남은 것

- **실기기 iPhone + iPad**: 찾기·초대 물음·연결, 왕복 시간(목표 50ms 아래), 떠다니는 십자키 손맛, 진동 되돌림, 가상 패드 숨김/복귀, iPhone 이 뒤로 갔다 올 때 재연결.
- 배치 편집기 연결(조건 1 의 "옮기고 키울 수 있고")과 여러 배치: 다음 빌드 이후. 지금은 크기 슬라이더(85~120%)와 떠다니기 켜고 끄기만.
- iPhone 의 기기 이름이 iOS 16+ 에서 "iPhone" 처럼 일반 이름으로 나올 수 있다. 여러 대면 구분이 안 되니 필요하면 모델명을 붙인다.
- 테스트 문안·사이트 패치노트는 빌드 때.
