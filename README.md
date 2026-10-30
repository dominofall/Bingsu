# 빙수 (Bingsu)

PC·웹용으로 만들어진 게임을 iPhone·iPad 에서 가상 패드나 실제 컨트롤러로 돌리는 iOS/iPadOS 런처입니다.

- **Electron·로컬 웹 게임** — zip 으로 가져와 기기 안에서 실행. 저장 데이터는 PC 백업과 호환되고 iCloud 로 iPhone ↔ iPad 이어하기
- **브라우저 게임** — 주소로 추가해 전체화면 + 가상 패드로 조작
- **RPG Maker XP 게임** — mkxp-z 기반 실행기(놋그릇, `BrassBowl`)로 실행
- **Bingsu** — 앱에 들어 있는 기본 게임. 빙수가 직접 만든 작은 빙수 가게 게임(A 연타로 얼음 갈기, 십자키로 토핑, 단계·콤보)으로, 처음 설치해도 목록이 비지 않고 가상 패드·컨트롤러·진동을 바로 확인할 수 있다

앱 폴더 구조는 [BingsuApp/README.md](BingsuApp/README.md) 를 보세요.

## 게임 파일은 포함하지 않습니다

이 저장소와 앱에 든 게임은 빙수가 직접 만든 "Bingsu"뿐입니다. 다른 게임은 각 제작자·권리자의 것이므로, 사용자가 정당하게 구한 파일을 직접 가져와야 합니다. 저장소에는 `.gitignore` 로 게임 폴더(`Games/` 등), 추출물(`*.asar`, `*.exe`, `*.dll`), 저장 데이터(`Saves/`), 서명·API 키 파일이 모두 제외돼 있습니다. 브라우저 게임은 각 운영자의 사이트를 앱 안 브라우저로 여는 것뿐입니다.

빙수는 비영리 개인 프로젝트이며, 실행할 수 있는 게임의 제작자·권리자와 무관합니다.

## 빌드

요구 사항: macOS + Xcode 26 이상, [xcodegen](https://github.com/yonaskolb/XcodeGen), iOS 26 이상 기기 또는 시뮬레이터.

저장소 맨 위 폴더에서:

```bash
cd BingsuApp && xcodegen generate && xcodebuild -project BingsuApp.xcodeproj -scheme Bingsu -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/SimDD build
```

- RPG Maker XP 실행기 엔진(`BrassBowl.framework`)은 저장소에 없고 따로 만듭니다: [BingsuApp/BrassBowl/README.md](BingsuApp/BrassBowl/README.md). 없이 빌드하면 RPG Maker XP 게임만 "준비 중"으로 보입니다.
- 실기기는 `DEVELOPMENT_TEAM=<팀 ID>` 를 명령줄로 넘깁니다. 팀 ID·서명 파일·App Store Connect API 키는 저장소에 넣지 않습니다.
- 번들 ID(`com.minwoo.bingsu`)와 iCloud 컨테이너(`iCloud.com.minwoo.bingsu`)는 원작자 계정에 묶여 있습니다. 직접 기기에 설치하거나 배포하려면 `BingsuApp/project.yml` 의 `PRODUCT_BUNDLE_IDENTIFIER` 와 `Bingsu.entitlements`·`Freezer/Igloo.swift`(`containerID`) 의 iCloud 컨테이너 이름을 자기 것으로 바꾸고 `xcodegen generate` 를 다시 돌리세요. iCloud 를 안 쓰면 entitlements 에서 iCloud 항목을 빼도 동기화만 꺼지고 나머지는 그대로 돌아갑니다.

## 기여

- **효과음 진동표** — 게임이 진동을 직접 요청하지 않아도, 효과음 파일 이름에 맞춰 컨트롤러를 울리는 표(게임마다 JSON 하나)를 PR 로 보내 주세요. 형식·검사 기준·예시: [docs/rumble/README.md](docs/rumble/README.md)
- **가상 패드 스킨** — 패드의 색·재질은 `SpoonSkin`([BingsuApp/Bingsu/Spoon/SpoonFace.swift](BingsuApp/Bingsu/Spoon/SpoonFace.swift)) 한 구조체로 정해집니다. 새 스킨은 이 구조체 값 한 벌로 PR 을 보내 주세요(흐림 합성처럼 게임 위에서 발열이 큰 효과는 받지 않습니다).
- PR 에 게임 파일·게임 화면 캡처·저장 데이터·서버 주소를 넣지 마세요.

## 보안·개인정보 원칙 (요약)

- 웹 게임은 신뢰하지 않습니다. 게임에서 앱으로 오는 값은 모두 형식·범위를 검증하고, 원격 웹 게임의 로그인 토큰은 파일이나 iCloud 로 내보내지 않습니다.
- 가져온 zip 은 경로 탈출(zip slip)·크기·여유 공간을 검사한 뒤 풉니다.
- 다운로드는 사용자가 직접 넣은 https 주소만 받습니다.
- 성능·진단 기록에는 기기 모델·OS·앱 버전·수치만 남기고 사용자 식별 정보를 넣지 않습니다.

## 라이선스

빙수는 [GPL-3.0](LICENSE) 입니다. RPG Maker XP 실행기 엔진(mkxp-z-apple-mobile, GPL-3.0)이 들어가므로 앱 전체를 GPL-3.0 으로 배포합니다. 포함된 오픈소스 구성 요소의 고지와 엔진 소스 받는 법은 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) 에 있습니다.
