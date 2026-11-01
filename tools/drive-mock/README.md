# Google Drive 흉내 서버 (drive-mock)

빙수의 Google Drive 동기화(`Freezer/DriveTicket·DriveCounter·DriveShelf.swift`)를 실제 Google 계정 없이 시뮬레이터에서 확인하는 로컬 서버.
Python 표준 라이브러리만 쓴다. 동의 화면 → 토큰 → Drive v3 `appDataFolder` 읽기·쓰기·지우기까지 같은 모양으로 답한다.

## 띄우기

```bash
python3 tools/drive-mock/server.py --dir /tmp/drive-mock --port 8799
```

- `--dir`: "Drive" 내용. `meta.json`(파일 메타·토큰·흉내 상태), `files/<id>__<이름>`(내용), `sessions/`(이어 올리기 조각). 시뮬레이터 두 대가 같은 서버를 보면 같은 Drive 를 쓰는 것과 같다
- `--expires`: 액세스 토큰 수명(초, 기본 3600). 짧게 주면 갱신 경로를 본다
- `--page-size`: 목록 한 페이지 최대 개수. 줄이면 `nextPageToken` 넘기기를 본다
- `--token`: 이 고정 토큰도 받는다(앱의 `BINGSU_DRIVE_TOKEN` 과 함께, 동의 화면 없이 바로 호출할 때)
- 로그에는 경로만 남긴다(쿼리·토큰 없음). 시뮬레이터에서 `127.0.0.1` 은 이 Mac 이다

## 앱을 흉내 서버에 붙이기 (디버그 빌드만)

```bash
SIMCTL_CHILD_BINGSU_ALLOW_HTTP=1 SIMCTL_CHILD_BINGSU_DRIVE_BASE_URL=http://127.0.0.1:8799 \
  xcrun simctl launch --console-pty <udid> com.minwoo.bingsu
```

- `BINGSU_DRIVE_BASE_URL` 은 `http://127.0.0.1` 또는 `http://localhost` 만 받는다. 동의 화면·토큰·철회·Drive 주소가 모두 이 서버로 간다(로그 `[Drive] 흉내 서버 사용`)
- 클라이언트 ID 가 없어도(`Secrets.xcconfig` 없음) 흉내 서버에서는 `bingsu.mock` 으로 동작한다. 토큰은 키체인 계정 `mock` 에 따로 둬 실제 연결과 섞이지 않는다
- `BINGSU_DRIVE_CONNECT=1` 이면 켤 때 "Google Drive 연결" 을 누른 것처럼 동의 화면을 띄워 연결한다(흉내 서버는 바로 되돌림 주소로 보낸다)
- `BINGSU_SELFTEST=1` 이면 `[Igloo] selftest ok (46개)` — PKCE·경로 규칙·오류 분류·선반 이전 자가 테스트
- 흉내 서버 없이 화면만 보려면 `BINGSU_FAKE_DRIVE=<폴더>`: 로컬 폴더를 Drive 선반처럼 쓴다(네트워크·토큰 없음)

## 흉내 바꾸기

```bash
curl -X POST 'http://127.0.0.1:8799/mock/mode?set=quota'
curl http://127.0.0.1:8799/mock/state
```

| set | 동작 | 앱에서 보이는 것 |
|---|---|---|
| `normal` | 정상 | |
| `quota` | 올리기 403 `storageQuotaExceeded` | "Google Drive 공간이 부족해요", 로컬은 그대로 |
| `invalid_grant` | 모든 호출 401 + 토큰 갱신 400 `invalid_grant` | 키체인 지움, "Google Drive 연결이 끊겼어요 · 다시 연결해 주세요" |
| `expire` | 지금 액세스 토큰을 한 번 무효로 | 401 → 갱신 → 다시 시도해 성공 |
| `rate&count=N` | 다음 N개 요청 429 `rateLimitExceeded` | 1·2·4·8초 + 지터로 다시 시도 |
| `drop_chunk` | 다음 이어 올리기 둘째 조각을 받고 응답 없이 끊음 | `bytes */N` 로 위치 확인 뒤 이어서 |
| `die_chunk` | 첫 조각을 저장한 뒤 서버 종료 | 오프라인 → 서버를 다시 띄우면 이어서 |

서버를 끄면 앱은 "오프라인 · 다음에 다시 맞춰요" 로 멈추고, 다시 띄운 뒤 앱이 활성화되면 이어서 맞춘다.

## 실제 Google 과 다른 점

- 동의 화면이 없다: `/o/oauth2/v2/auth` 가 PKCE 값(`S256`)만 확인하고 바로 `<되돌림 주소>?code=…&state=…` 로 302. 계정·동의·테스트 사용자 제한·7일 갱신 토큰 만료(테스트 상태)는 흉내 내지 않는다
- 아무 클라이언트 ID 나 받는다. 갱신 토큰은 만료되지 않는다(`invalid_grant` 흉내로만 끊는다)
- `spaces=appDataFolder` 만 받는다(아니면 403). `q`·`orderBy`·`fields` 는 무시하고 모든 필드를 준다. 목록 순서는 id 순
- `md5Checksum`·`size`·`modifiedTime`·`appProperties` 는 실제처럼 채운다. `appProperties` 의 키+값 124바이트 제한은 검사하지 않는다(앱 쪽 `DriveShelf.fit` 이 지킨다)
- 할당량(`about.storageQuota`)은 한도 15GB 고정, 사용량은 이 서버에 올린 파일 합. 실제로 차는 일은 `quota` 흉내로만, 사용자별 요청 한도는 `rate` 흉내로만 본다
- 이어 올리기 세션 주소는 이 서버(`/upload/drive/v3/files?upload_id=…`). 세션 만료(실제 1주)는 없다
