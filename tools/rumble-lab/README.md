# 진동 실험실 (rumble-lab)

빙수 진동을 시험하는 아주 작은 로컬 게임(팥빙수 형식: `package.json` + `dist/index.html` + `assets/`).

- ① 게임이 직접 요청: 표준 Gamepad API `vibrationActuator.playEffect("dual-rumble", …)` 로 세기·길이·모터별 진동
- ② 효과음에 맞춘 진동: 게임은 `assets/lab_*.wav` 만 재생하고, 빙수가 번들 진동표 `Resources/Rumble/rumble-lab.json` 으로 울림 (`lab_beep.wav` 는 표에 없어 진동이 없어야 정상)

십자키로 고르고 A 로 누르거나 화면을 누른다.

## zip 만들기

```bash
cd tools/rumble-lab && python3 make_sounds.py game/assets && (cd game && zip -qr ../rumble-lab.zip .)
```

zip 은 커밋하지 않는다. 폰에서는 Files 로 zip 을 빙수로 열거나, 개발 빌드면
`xcrun devicectl device copy to --domain-type appDataContainer --domain-identifier com.minwoo.bingsu --source rumble-lab.zip --destination Documents/rumble-lab.zip`
뒤 `BINGSU_IMPORT=rumble-lab.zip` 로 실행.
