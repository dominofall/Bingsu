# 서드파티 라이선스

빙수(Bingsu)에 포함되거나 빌드에 쓰이는 오픈소스 구성 요소와 그 라이선스입니다. 앱에 든 게임은 빙수가 직접 만든 기본 게임 "Bingsu"(`BingsuApp/Bingsu/Resources/SampleGame/`) 하나뿐입니다. 다른 게임은 앱에 포함되지 않으며, 브라우저 게임은 각 운영자의 웹 서비스를 앱 안 브라우저로 여는 것일 뿐 이 저장소에 코드가 들어 있지 않습니다.

| 구성 요소 | 버전 | 라이선스 | 용도 |
|---|---|---|---|
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | MIT | 게임 zip 안전 해제 |
| [SwiftGlass](https://github.com/1998code/SwiftGlass) | 26.0.1 | MIT | 일시정지 화면과 게임 칩의 유리 효과 |
| [@wasm-audio-decoders/ogg-vorbis](https://github.com/eshaz/wasm-audio-decoders) | 0.1.20 | MIT | iOS WebKit 이 못 푸는 Ogg Vorbis 효과음·BGM 디코딩 (`BingsuApp/Bingsu/Resources/ogg-vorbis-decoder.min.js`) |
| libvorbis · libogg (위 디코더에 WebAssembly 로 포함) | — | BSD-3-Clause (Xiph.Org) | Vorbis 디코딩 |
| [Phaser](https://github.com/phaserjs/phaser) | 3.80.1 | MIT | 기본 게임 "Bingsu"의 픽셀 장면·입자 효과 (`SampleGame/dist/phaser.min.js`) |
| [ZzFX](https://github.com/KilledByAPixel/ZzFX) (Micro) | 1.4.0 | MIT | 기본 게임 "Bingsu"의 효과음 합성 (`SampleGame/dist/zzfx.js`) |
| [mkxp-z-apple-mobile](https://github.com/mateo-m/mkxp-z-apple-mobile) (mkxp-z 의 iOS 포크) | v9 (68efcd3, 고치지 않음) | GPL-3.0 + 추가 조건 (mkxp-z 부분은 GPL-2.0-or-later) | RPG Maker XP 게임 실행 엔진 `BrassBowl.framework` — 딸린 라이브러리는 아래 "RPG Maker XP 엔진" 절 |

RPG Maker XP 게임은 mkxp-z-apple-mobile 을 묶은 `BrassBowl.framework`(놋그릇)로 돌립니다. 이 엔진은 GNU GPL 이므로, 엔진을 묶어 넣은 빙수 앱 배포본도 GPL 조건(소스 제공 포함)을 따라야 합니다. 아래 "RPG Maker XP 엔진" 절을 보세요.

---

## ZIPFoundation

```
MIT License

Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## @wasm-audio-decoders/ogg-vorbis

```
MIT License

Copyright (c) 2021-2025 Ethan Halsall

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## libvorbis / libogg (Xiph.Org Foundation)

```
Copyright (c) 2002-2020 Xiph.org Foundation

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Phaser

```
The MIT License (MIT)

Copyright (c) 2024 Richard Davey, Phaser Studio Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## ZzFX

```
MIT License

Copyright (c) 2019 Frank Force

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## SwiftGlass

```
MIT License

Copyright (c) 2025 MING

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## RPG Maker XP 엔진 (mkxp-z-apple-mobile · mkxp-z)

> mkxp-z-apple-mobile, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/mkxp-z-apple-mobile

- **mkxp-z-apple-mobile** — GNU GPL 3.0, 원저작자가 7조로 덧붙인 조건(저작자 표시·출처·이름 사용)이 있음. 원문: 소스의 `LICENSE`, `ADDITIONAL-TERMS.md`. 빙수는 이 조건에 따라 위 저작자 표시를 앱 안 "설정 › 오픈소스 라이선스" 화면에 다른 고지와 같은 크기로, 주소를 누를 수 있게 보입니다.
- **mkxp-z** — RGSS player for multiple platforms. Copyright (C) 2020-2024 Splendide Imaginarius and contributors, Copyright (C) 2013-2023 Jonas Kulla and contributors. GNU GPL 2.0 or later. https://github.com/mkxp-z/mkxp-z
- 빙수가 넣은 판: 태그 v9, 커밋 `68efcd3`. 소스는 고치지 않았고, 빌드 옵션만 빙수 쪽 스크립트(`BingsuApp/BrassBowl/build-framework.sh`)로 정합니다.

### 소스 받는 법

- 엔진: `git clone https://github.com/mateo-m/mkxp-z-apple-mobile && git -C mkxp-z-apple-mobile checkout 68efcd3`
- 엔진을 하나의 프레임워크로 묶는 방법과 앱에 넣는 방법: 이 저장소의 `BingsuApp/BrassBowl/` (README·빌드 스크립트)
- GPL 은 엔진이 든 빙수 앱 전체에 소스 제공을 요구하므로, 엔진이 든 판을 배포할 때는 빙수 소스도 함께 공개해야 합니다.

### 엔진에 같이 든 라이브러리·글꼴·데이터

전문은 프레임워크 안 `BrassBowl.framework/licenses.json`(앱 화면에서 항목을 누르면 보임)에 있습니다. 포크의 목록에 ANGLE·libpng·FluidSynth 를 덧붙였습니다(`BingsuApp/BrassBowl/extra-licenses.json`).

| 구성 요소 | 라이선스 |
|---|---|
| theoraplay | zlib License |
| json5pp | MIT |
| cpp-httplib | MIT |
| LUrlParser | MIT |
| libnsgif | MIT |
| rapidcsv | BSD 3-Clause |
| sigslot | MIT |
| H-Mode7 | Terms of the original release |
| Ruby | Ruby License / BSD 2-Clause |
| libyaml | MIT |
| SDL2 | zlib License |
| SDL2_image | zlib License |
| stb_image | MIT or public domain |
| miniz | Public domain |
| TinyJPEG | Public domain |
| NanoSVG | zlib License |
| QOI | MIT |
| SDL2_sound | zlib License |
| dr_flac | MIT-0 or public domain |
| dr_mp3 | MIT-0 or public domain |
| stb_vorbis | MIT or public domain |
| libmodplug | Public domain |
| SDL2_ttf | zlib License |
| FreeType | FreeType License (FTL) |
| pixman | MIT |
| libogg | BSD 3-Clause |
| libvorbis | BSD 3-Clause |
| libtheora | BSD 3-Clause |
| PhysicsFS | zlib License |
| uchardet | MPL 1.1 / GPL 2.0 / LGPL 2.1 |
| OpenAL Soft | LGPL 2.0 or later |
| OpenSSL | Apache License 2.0 |
| Liberation fonts | SIL Open Font License 1.1 |
| WenQuanYi Micro Hei | Apache License 2.0 |
| SDL_GameControllerDB | zlib License |
| CA certificates | MPL 2.0 |
| ANGLE | BSD 3-Clause |
| libpng | PNG Reference Library License v2 |
| [FluidSynth](https://github.com/FluidSynth/fluidsynth) 2.5.7 (고치지 않음, MIDI 합성) | LGPL-2.1 or later |

OpenAL Soft(LGPL 2.0 or later)와 FluidSynth(LGPL 2.1 or later)는 `BrassBowl.framework` 안에 정적으로 묶여 있습니다. LGPL 에 따라 사용자가 고친 판으로 다시 링크할 수 있도록, 프레임워크는 위 빌드 스크립트(`build-fluidsynth.sh`, `build-framework.sh`)로 같은 방법으로 다시 만들 수 있습니다. FluidSynth 소스: `git clone --depth 1 --branch v2.5.7 https://github.com/FluidSynth/fluidsynth`
