# 팥빙수(Electron 호환) 시험용 작은 게임

빙수가 직접 만든 아주 작은 Electron 식 게임 세 개. 실제 게임은 커밋할 수 없어서 이것으로 흉내 계층을 확인한다
(명세 `docs/engines/IMPLEMENTATION-electron.md` §8).

| 폴더 | 확인하는 것 |
|---|---|
| `electron-node/` | `nodeIntegration: true`. 화면에서 `require('electron')`·상대 모듈·`fs.readFileSync`(JSON·그림 → data URL)·`module.exports`, 메인에서 userData JSON 읽고 쓰기(.tmp → rename)·`setContentSize`·`setZoomFactor`(레이아웃 960×640), `<audio>` 의 wav·ogg |
| `electron-preload/` | `contextIsolation` + `preload` + `contextBridge` 로 `window.api.save/load`, 하위 폴더(`userData/saves/`) 저장 |
| `electron-plain/` | 순수 브라우저 코드 + `localStorage`, 메인은 창만 만든다(시작 화면이 하위 폴더 `page/index.html`) |

각 화면은 확인 결과를 `OK`/`FAIL` 줄로 보여 주고 `console.warn("[fixture] …")` 로도 남긴다 (빙수 실행기는 warn·error 만 로그로 넘긴다).

시뮬레이터에 넣기 (저장소 밖 임시 폴더에서 zip):

```bash
cd tools/compat-fixtures && zip -qr "$TMPDIR/electron-node.zip" electron-node
```

`RedBeanSelfTest`(디버그, `BINGSU_SELFTEST=1`)는 이 폴더들을 `RedBeanProbe` 로 읽어 판별 결과를 본다.
