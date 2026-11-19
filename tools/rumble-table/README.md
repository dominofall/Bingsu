# 진동 1차 표 시험 (rumble-table)

[1차 표](../../docs/rumble/TABLE-v1.md)의 상황별 진동을 손으로 느껴 보는 작은 로컬 게임(팥빙수 형식, 2026-11-19).

- 효과음 파일 이름이 Essentials 이름 그대로(`Battle damage normal.wav` 등)라서, 게임 표 없이 빙수의 **포켓몬 공통 기본 표**로 울린다. 진동표가 없는 Essentials 팬게임과 같은 조건.
- 버튼 15개: 상황 14개 + "메뉴 커서"(표에 없음, 안 울려야 정상). 버튼에 묵직·가벼움·길이(초)가 적혀 있다(`events.json` 값을 옮겨 적은 것이라 표를 고치면 여기도 고친다).
- 연출 5개: 포획 전체(던지기 → 딸깍, 흔들림 3번), 한 턴(굉장한 공격 → 기절), 화면 흔들림 약·강(`Game_Screen.prototype.startShake`), 겹침(흔들림 9 + 보통 타격 → 한 번만).
- 십자키로 고르고 A, 또는 화면을 누른다.

`BINGSU_KEYDEBUG=1` 로 실행하면 `[Bowl] sfx battle damage normal.wav -> rumble`, `(겹침으로 건너뜀)` 로그가 나온다.

## zip 만들기와 넣기

```bash
cd tools/rumble-table && python3 make_sounds.py game/assets && (cd game && zip -qr ../rumble-table.zip .)
```

zip 은 커밋하지 않는다. 폰에서는 Files 로 zip 을 빙수로 열거나, 개발 빌드면

```bash
xcrun devicectl device copy to --device <기기> --domain-type appDataContainer --domain-identifier com.minwoo.bingsu --source rumble-table.zip --destination Documents/rumble-table.zip
xcrun devicectl device process launch --device <기기> --terminate-existing --environment-variables '{"BINGSU_IMPORT":"rumble-table.zip"}' com.minwoo.bingsu
```
