import Foundation

/// 유리그릇에 주입하는 JS. 세 가지 일만 한다:
/// 1. 냉동실: localStorage 스냅샷 복원 / 주기 전송   2. 온도계: rAF 프레임 측정   3. 숟가락: KeyboardEvent 합성
enum BowlScripts {
    /// 문서 시작 전: 냉동실 복원 + 공용 브리지
    /// `freezer == false`(원격 웹 게임)면 localStorage 를 읽지도, 파일로 보내지도 않는다 — 로그인 토큰이 파일로 새는 것을 막기 위해.
    static func atDocumentStart(restore: Freezer.Snapshot?, keyPrefix: String, freezer: Bool, desktopSpoof: Bool,
                                renderScale: Double? = nil, fpsCap: Int? = nil, volume: Double = 1, keysToDocument: Bool = false) -> String {
        let restoreJSON: String
        if let restore, let data = try? JSONSerialization.data(withJSONObject: ["at": restore.savedAt, "data": restore.entries] as [String: Any]),
           let s = String(data: data, encoding: .utf8) {
            restoreJSON = s
        } else { restoreJSON = "null" }
        return """
        (() => {
          const PREFIX = \(jsString(keyPrefix));
          const FREEZER = \(freezer ? "true" : "false");
          const DESKTOP = \(desktopSpoof ? "true" : "false");
          // RPG Maker MV·MZ 는 document 에서 키를 듣는다 (window 에 보낸 이벤트는 document 로 내려가지 않음)
          const KEYS_TO_DOCUMENT = \(keysToDocument ? "true" : "false");
          const restore = FREEZER ? \(restoreJSON) : null;
          // 냉동실 → localStorage (앱 파일이 진실의 원천: 5초마다 갱신되므로 최대 5초 손실)
          // MARK 는 네이티브가 save.json 을 쓴 시각. 파일 시각과 다르면 파일이 바뀐 것(되돌리기·가져오기)이라 파일로 덮는다.
          const MARK = \(jsString(Freezer.markerKey));
          let restored = "none";
          try {
            if (restore) {
              const mine = Object.keys(localStorage).filter(k => k.startsWith(PREFIX));
              const mark = localStorage.getItem(MARK);
              if (!mine.length || mark !== String(restore.at)) {
                for (const k of mine) localStorage.removeItem(k);
                for (const [k, v] of Object.entries(restore.data)) localStorage.setItem(k, v);
                localStorage.setItem(MARK, String(restore.at));
                restored = mine.length ? "file-changed" : "empty";
              } else { restored = "up-to-date"; }
            }
          } catch (e) { restored = "error"; }

          const post = (name, body) => { try { window.webkit.messageHandlers[name].postMessage(body); } catch (e) {} };

          // 화질 "낮음": 게임(Phaser·Three.js)이 캔버스 해상도를 정하기 전에 devicePixelRatio 를 덮어쓴다
          const RENDER_SCALE = \(renderScale.map { String($0) } ?? "null");
          if (RENDER_SCALE) try { Object.defineProperty(window, "devicePixelRatio", { configurable: true, get: () => RENDER_SCALE }); } catch (e) {}
          post("bowl", { event: "dpr", msg: String(window.devicePixelRatio) });

          // 일시정지: rAF 콜백을 묶어 두고, 오디오 컨텍스트를 suspend 한다 (홈으로 나갔을 때)
          let PAUSED = false, resumedGap = false; const pendingRAF = []; const contexts = new Set();
          // 게임별 소리 크기: 컨텍스트마다 destination 앞에 GainNode 를 하나 끼우고 게임에는 그것을 destination 으로 보여 준다
          let VOLUME = \(min(1, max(0, volume))); const masters = new WeakMap();
          const setVolume = (v) => {
            const n = Number(v); VOLUME = Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 1;
            for (const c of contexts) { const g = masters.get(c); if (g) try { g.gain.setValueAtTime(VOLUME, c.currentTime); } catch (e) { g.gain.value = VOLUME; } }
          };
          const rafOrig = window.requestAnimationFrame.bind(window);
          const cafOrig = window.cancelAnimationFrame.bind(window);
          // 프레임 제한: 콜백을 모아 두고 화면 갱신 몇 번에 한 번만 넘긴다 (60Hz 에서 30 이면 한 번 건너뜀).
          // 게임은 넘겨받은 시각 차이로 움직이므로 애니메이션 속도는 그대로다. id 는 진짜 rAF id 와 겹치지 않게 큰 수부터
          let CAP = \(fpsCap.map { String(max(0, min(120, $0))) } ?? "0");
          const capQueue = new Map(); let capNextId = 1e9, capPending = false, capLast = 0;
          const capTick = (t) => {
            capPending = false;
            if (CAP && t - capLast < 1000 / CAP - 4) { capPending = true; rafOrig(capTick); return; }
            capLast = t;
            const due = Array.from(capQueue.values()); capQueue.clear();
            for (const cb of due) { try { cb(t); } catch (e) { setTimeout(() => { throw e; }); } }
          };
          window.requestAnimationFrame = (cb) => {
            if (PAUSED) { pendingRAF.push(cb); return 0; }
            if (!CAP && !capQueue.size) return rafOrig(cb);
            const id = capNextId++; capQueue.set(id, cb);
            if (!capPending) { capPending = true; rafOrig(capTick); }
            return id;
          };
          window.cancelAnimationFrame = (id) => { if (!capQueue.delete(id)) cafOrig(id); };
          const setFpsCap = (n) => {
            const v = Number(n); CAP = Number.isFinite(v) && v >= 10 && v <= 120 ? Math.round(v) : 0;
            post("bowl", { event: "fps", msg: "cap " + (CAP || "none") });
          };
          if (CAP) post("bowl", { event: "fps", msg: "cap " + CAP });
          for (const name of ["AudioContext", "webkitAudioContext"]) {
            const C = window[name]; if (!C) continue;
            const Wrapped = new Proxy(C, { construct(t, args) {
              // (latencyHint "playback" 을 넣어 봤지만 iOS WebKit 은 무시: baseLatency 2.7ms 그대로, 2026-10-30 iPhone 16)
              const c = Reflect.construct(t, args); contexts.add(c);
              try {
                const real = c.destination, g = c.createGain();
                g.gain.value = VOLUME; g.connect(real); masters.set(c, g);
                // 채널 수 등 destination 고유 값을 읽는 게임을 위해 진짜 것을 비춰 준다
                for (const k of ["maxChannelCount"]) { try { Object.defineProperty(g, k, { get: () => real[k] }); } catch (e) {} }
                Object.defineProperty(c, "destination", { configurable: true, get: () => g });
              } catch (e) { post("bowl", { event: "audio", msg: "volume node failed " + e }); }
              post("bowl", { event: "audio", msg: "context sr=" + c.sampleRate + " base=" + (Number(c.baseLatency) * 1000).toFixed(1) + "ms" });
              // iOS 가 오디오를 끊으면(블루투스 경로 변경 등) 컨텍스트가 interrupted/suspended 로 바뀐다.
              // 게임은 화면 터치 때만 다시 켜므로 컨트롤러만 쓰면 소리가 영영 멈춘다 → 우리가 멈춘 게 아니면 다시 켠다
              try { c.addEventListener("statechange", () => { post("bowl", { event: "audio", msg: String(c.state) }); kickSoon(); }); } catch (e) {}
              return c;
            } });
            window[name] = Wrapped;
          }
          // 소리 진단: 마지막 decodeAudioData 에 걸린 시간 (Ogg 폴리필보다 바깥에서 재므로 그것도 포함)
          let lastDecodeMs = -1, lastDecodeAt = 0;
          for (const name of ["AudioContext", "webkitAudioContext"]) {
            const C = window[name]; if (!C || !C.prototype || !C.prototype.decodeAudioData) continue;
            const orig = C.prototype.decodeAudioData;
            C.prototype.decodeAudioData = function (buf, ok, err) {
              const t0 = performance.now();
              const done = () => { lastDecodeMs = performance.now() - t0; lastDecodeAt = performance.now(); };
              const r = orig.call(this, buf, ok ? (ab) => { done(); ok(ab); } : undefined, err);
              if (r && typeof r.then === "function") r.then(done, () => {});
              return r;
            };
          }
          const audioStat = () => {
            for (const c of contexts) {
              return { sr: c.sampleRate, state: String(c.state), lat: Number(c.baseLatency) || 0, t: c.currentTime,
                       decMs: lastDecodeMs, decAgo: lastDecodeAt ? performance.now() - lastDecodeAt : -1 };
            }
            return null;
          };
          // 일시정지 중이 아니고 화면이 보이면, 멈춘 컨텍스트를 다시 켠다 (네이티브가 오디오 끊김이 끝났을 때도 부름)
          let kickTimer = 0;
          const kickAudio = () => {
            if (PAUSED || document.hidden) return;
            for (const c of contexts) {
              if (c.state === "interrupted" || c.state === "suspended") {
                try { c.resume().then(() => post("bowl", { event: "audio", msg: "resumed " + c.state }), (e) => post("bowl", { event: "audio", msg: "resume failed " + e })); } catch (e) {}
              }
            }
          };
          const kickSoon = () => { clearTimeout(kickTimer); kickTimer = setTimeout(kickAudio, 300); };
          // 소리 시계 감시: "running" 인데 currentTime 이 2초째 그대로면 WebKit 출력이 멈춘 것 → 껐다 켠다
          // (2026-10-30 iPhone 16 포켓로그: 상태는 running 인데 이어폰·스피커 모두 무음)
          const clockSeen = new WeakMap();
          const restartAudio = (why) => {
            for (const c of contexts) {
              if (c.state === "closed") continue;
              post("bowl", { event: "audio", msg: "restart (" + why + ") t=" + c.currentTime.toFixed(2) });
              try { c.suspend().then(() => c.resume()).catch(() => {}); } catch (e) {}
            }
          };
          let clockTicks = 0;
          setInterval(() => {
            clockTicks++;
            for (const c of contexts) {
              const t = c.currentTime, prev = clockSeen.get(c);
              if (window.__bingsuKeyDebug && clockTicks % 10 === 0) post("bowl", { event: "audio", msg: "clock " + c.state + " t=" + t.toFixed(2) });
              if (c.state !== "running" || PAUSED || document.hidden) { clockSeen.set(c, { t, n: 0 }); continue; }
              const n = prev && prev.t === t ? prev.n + 1 : 0;
              clockSeen.set(c, { t, n });
              if (n === 2) restartAudio("clock stuck");
            }
          }, 1000);
          document.addEventListener("visibilitychange", kickSoon);
          const pause = () => {
            if (PAUSED) return; PAUSED = true;
            for (const c of contexts) { try { if (c.state === "running") c.suspend(); } catch (e) {} }
          };
          const resume = () => {
            if (!PAUSED) return; PAUSED = false; resumedGap = true;
            // 게임별 재개 처리 (MV·MZ: 멈춘 시간 따라잡기 막기, BowlScripts.nwShim)
            try { if (window.__bingsuResumeHook) window.__bingsuResumeHook(); } catch (e) {}
            for (const c of contexts) { try { if (c.state === "suspended") c.resume(); } catch (e) {} }
            const cbs = pendingRAF.splice(0); for (const cb of cbs) window.requestAnimationFrame(cb);
          };
          // 콘솔 에러 → 네이티브 로그 (디버깅용)
          window.addEventListener("error", (e) => post("bowl", { event: "error", msg: String(e.message), src: String(e.filename) + ":" + e.lineno }));
          window.addEventListener("unhandledrejection", (e) => post("bowl", { event: "error", msg: "unhandledrejection: " + String(e.reason && (e.reason.stack || e.reason)) }));
          // 객체는 이름만 적는다: 게임이 큰 객체(포켓몬 데이터 등)를 경고로 찍을 때 JSON.stringify 하면 그동안 화면이 굳는다
          const brief = (x) => {
            if (typeof x === "string") return x;
            if (x instanceof Error) return String(x.stack || x);
            if (x === null || typeof x !== "object") return String(x);
            return "[" + ((x.constructor && x.constructor.name) || "Object") + "]";
          };
          for (const level of ["error", "warn"]) { const orig = console[level].bind(console); console[level] = (...a) => { post("bowl", { event: level, msg: a.map(brief).join(" ").slice(0, 2000) }); orig(...a); }; }
          const snapshot = () => {
            const out = {};
            if (!FREEZER) return out;
            try { for (const k of Object.keys(localStorage)) if (k.startsWith(PREFIX)) out[k] = localStorage.getItem(k); } catch (e) {}
            return out;
          };
          let lastJSON = "";
          const flush = () => {
            const s = snapshot(); const j = JSON.stringify(s);
            if (j !== lastJSON && Object.keys(s).length) { lastJSON = j; post("freezer", { at: Date.now(), data: s }); }
          };
          setInterval(flush, 5000);
          document.addEventListener("visibilitychange", () => { if (document.hidden) flush(); });
          window.addEventListener("pagehide", flush);

          // 온도계: 프레임 간격 측정
          const frames = []; let last = performance.now(); let stutters = 0;
          // 0.25초 넘게 멈춘 프레임은 로그로 남긴다 (멈춤 원인 찾기용). 일시정지에서 막 돌아온 첫 프레임은 뺀다
          const tick = (t) => {
            const d = t - last; last = t; frames.push(d); if (d > 33.4 * 2) stutters++;
            if (d > 250 && !document.hidden && !resumedGap) post("bowl", { event: "stall", msg: d.toFixed(0) + "ms" });
            resumedGap = false;
            requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);
          setInterval(() => {
            if (!frames.length) return;
            const sorted = frames.slice().sort((a, b) => a - b);
            const sum = frames.reduce((a, b) => a + b, 0);
            const p95 = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))];
            post("thermometer", { fps: frames.length * 1000 / sum, p95: p95, stutters: stutters, audio: audioStat() });
            frames.length = 0; stutters = 0;
          }, 1000);

          // 숟가락: 네이티브 버튼 → KeyboardEvent (게임은 e.code 를 본다)
          const KEYS = { ArrowUp: ["ArrowUp", 38], ArrowDown: ["ArrowDown", 40], ArrowLeft: ["ArrowLeft", 37], ArrowRight: ["ArrowRight", 39],
                         KeyZ: ["z", 90], KeyX: ["x", 88], KeyM: ["m", 77], KeyB: ["b", 66], KeyR: ["r", 82], KeyF: ["f", 70], KeyV: ["v", 86],
                         KeyQ: ["q", 81], KeyW: ["w", 87], KeyE: ["e", 69], Space: [" ", 32], Enter: ["Enter", 13], Escape: ["Escape", 27],
                         ShiftLeft: ["Shift", 16], Digit1: ["1", 49], Digit2: ["2", 50], Digit3: ["3", 51], Digit4: ["4", 52], Digit5: ["5", 53], Digit6: ["6", 54] };
          // WKWebView 는 웹뷰가 직접 터치를 받기 전까지 document.hasFocus() 가 false 다.
          // 가상 패드가 터치를 가로채면 영원히 false 가 되어 게임의 패드 폴링이 멈추므로 항상 true 로 둔다.
          try { Object.defineProperty(Document.prototype, "hasFocus", { configurable: true, writable: true, value: function () { return true; } }); } catch (e) {}
          // 게임이 "터치 기기"로 판단하면 자체 터치 UI 를 켜고 패드 입력을 가로채므로, 데스크톱+게임패드처럼 보이게 한다 (7.4).
          // 자체 터치 UI 가 잘 된 웹 게임(포켓로그 등)은 반대로 터치 기기 그대로 둔다 (DESKTOP=false).
          if (DESKTOP) try { Object.defineProperty(navigator, "maxTouchPoints", { configurable: true, get: () => 0 }); } catch (e) {}
          if (DESKTOP) try {
            const origMM = window.matchMedia.bind(window);
            window.matchMedia = function (q) {
              const r = origMM(q);
              const s = String(q).split(" ").join("");
              if (/pointer:coarse|hover:none|any-pointer:coarse|any-hover:none/.test(s)) {
                return { media: r.media, matches: false, onchange: null, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {}, dispatchEvent() { return false; } };
              }
              if (/pointer:fine|hover:hover/.test(s)) {
                return { media: r.media, matches: true, onchange: null, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {}, dispatchEvent() { return false; } };
              }
              return r;
            };
          } catch (e) {}
          // 가상 게임패드: navigator.getGamepads() 에 표준 배치 패드 하나를 끼워 넣는다.
          // 게임은 실제 Xbox 패드가 꽂힌 것처럼 읽고, 필드/배틀 매핑도 게임이 스스로 한다.
          // id 는 Chrome 이 Xbox 360 패드에 붙이는 문자열 그대로: 게임들이 이 문자열로 Xbox 배치·아이콘을 고른다
          const PAD = { id: "Xbox 360 Controller (XInput STANDARD GAMEPAD Vendor: 045e Product: 028e)", index: 0, connected: false, mapping: "standard",
                        timestamp: performance.now(), axes: [0, 0, 0, 0],
                        buttons: Array.from({ length: 17 }, () => ({ pressed: false, touched: false, value: 0 })),
                        vibrationActuator: null, hapticActuators: [] };
          // 게임이 요청한 진동 → 실제 컨트롤러로 (Chrome 의 dual-rumble 형식). 값은 네이티브 쪽에서 다시 검증한다
          PAD.vibrationActuator = {
            type: "dual-rumble",
            playEffect(type, p) {
              const o = p || {};
              post("rumble", { duration: Number(o.duration) || 0, strong: Number(o.strongMagnitude) || 0, weak: Number(o.weakMagnitude) || 0 });
              return Promise.resolve("complete");
            },
            reset() { post("rumble", { duration: 0, strong: 0, weak: 0 }); return Promise.resolve("complete"); },
          };
          const origGet = typeof navigator.getGamepads === "function" ? navigator.getGamepads.bind(navigator) : () => [];
          Object.defineProperty(navigator, "getGamepads", { configurable: true, writable: true, value: function () {
            let list = [];
            try { const r = origGet(); if (r) for (let i = 0; i < r.length; i++) list.push(r[i] ?? null); } catch (e) {}
            // 가상 패드가 켜지면(가상 패드·실제 컨트롤러 모두 이 객체로 들어온다) 실제 패드는 숨겨 중복을 막는다
            if (PAD.connected) { PAD.index = 0; return [PAD]; }
            return list;
          } });
          const padEvent = (type) => {
            let ev; try { ev = new GamepadEvent(type, { gamepad: PAD }); } catch (e) { ev = new Event(type); try { Object.defineProperty(ev, "gamepad", { value: PAD }); } catch (_) {} }
            window.dispatchEvent(ev);
          };
          const setPad = (mask, lx, ly, rx, ry, lt, rt) => {
            if (!PAD.connected) { PAD.connected = true; padEvent("gamepadconnected"); post("bowl", { event: "pad", msg: "virtual gamepad connected" }); }
            for (let i = 0; i < 17; i++) { const on = (mask >>> i & 1) === 1; const b = PAD.buttons[i]; b.pressed = on; b.touched = on; b.value = on ? 1 : 0; }
            PAD.buttons[6].value = lt; PAD.buttons[7].value = rt;
            PAD.axes[0] = lx; PAD.axes[1] = ly; PAD.axes[2] = rx; PAD.axes[3] = ry;
            PAD.timestamp = performance.now();
          };

          window.__bingsu = {
            pad: setPad,
            padDisconnect() { if (PAD.connected) { PAD.connected = false; padEvent("gamepaddisconnected"); } },
            key(code, down) {
              // 표에 없는 글자/숫자 키는 코드에서 만든다 (KeyC → "c", 67 / Digit7 → "7", 55). Phaser 등은 keyCode 를 본다.
              const [key, keyCode] = KEYS[code] || (/^Key[A-Z]$/.test(code) ? [code[3].toLowerCase(), code.charCodeAt(3)]
                                     : /^Digit[0-9]$/.test(code) ? [code[5], code.charCodeAt(5)] : [code, 0]);
              const ev = new KeyboardEvent(down ? "keydown" : "keyup", { code, key, keyCode, which: keyCode, bubbles: true, cancelable: true });
              // keyCode/which 는 생성자 옵션으로는 안 박히는 브라우저가 있어 직접 덮어쓴다 (Phaser 는 keyCode 를 본다)
              try { Object.defineProperty(ev, "keyCode", { get: () => keyCode }); Object.defineProperty(ev, "which", { get: () => keyCode }); } catch (e) {}
              const target = document.activeElement && document.activeElement !== document.body ? document.activeElement : (KEYS_TO_DOCUMENT ? document : window);
              target.dispatchEvent(ev);
              if (down && window.__bingsuKeyDebug) post("bowl", { event: "key", msg: code + " keyCode=" + ev.keyCode + " prevented=" + ev.defaultPrevented + " target=" + (target === window ? "window" : target === document ? "document" : target.tagName) });
            },
            flush, pause, resume, kickAudio, restartAudio, setFpsCap, setVolume,
          };
          post("bowl", { event: "ready", msg: "restore=" + restored });
        })();
        """
    }

    /// Ogg Vorbis 폴리필: iOS WebKit 은 decodeAudioData 로 .ogg 를 못 풀기 때문에
    /// "OggS" 매직이면 WASM 디코더(@wasm-audio-decoders/ogg-vorbis, MIT)로 대신 푼다.
    /// 순서: WebKit 기본 디코딩(되면 그대로) → 워커에서 WASM → 메인 스레드에서 WASM.
    /// BGM 한 곡을 메인 스레드에서 풀면 그동안 rAF 가 멈춰 게임이 굳는다(타이틀·진화·바이옴 전환).
    /// 라이브러리의 WebWorker 판은 Ogg 파싱을 메인에 남기므로, 라이브러리 전체를 우리 워커에 넣는다.
    static func oggVorbisPolyfill(lib: String) -> String {
        """
        (() => {
          const lib = globalThis["ogg-vorbis-decoder"];
          if (!lib || !lib.OggVorbisDecoder) { return; }
          const post = (body) => { try { window.webkit.messageHandlers.bowl.postMessage(body); } catch (e) {} };
          const isOgg = (buf) => { const u = new Uint8Array(buf, 0, 4); return u[0] === 0x4f && u[1] === 0x67 && u[2] === 0x67 && u[3] === 0x53; };

          // 워커: 디코더 하나를 두고 요청을 차례로 푼다. 결과 채널은 복사해 transfer 로 돌려준다
          const WORKER_SRC = \(jsString(lib)) + `;
          (() => {
            const lib = self["ogg-vorbis-decoder"];
            let dec = null, chain = Promise.resolve();
            self.onmessage = ({ data: { id, bytes } }) => {
              chain = chain.then(async () => {
                try {
                  if (!dec) dec = new lib.OggVorbisDecoder();
                  await dec.ready;
                  const { channelData, samplesDecoded, sampleRate } = await dec.decodeFile(new Uint8Array(bytes));
                  const ch = channelData.map((c) => c.slice());
                  self.postMessage({ id, ch, samplesDecoded, sampleRate }, ch.map((c) => c.buffer));
                } catch (e) {
                  try { if (dec) dec.free(); } catch (_) {}
                  dec = null;
                  self.postMessage({ id, error: String((e && e.message) || e) });
                }
              });
            };
          })();`;
          let worker = null, workerBroken = false, nextId = 0;
          const waiting = new Map();
          const getWorker = () => {
            if (worker || workerBroken) return worker;
            try {
              worker = new Worker(URL.createObjectURL(new Blob([WORKER_SRC], { type: "text/javascript" })));
              worker.onmessage = ({ data }) => { const w = waiting.get(data.id); if (w) { waiting.delete(data.id); w(data); } };
              worker.onerror = (e) => {
                workerBroken = true; worker = null;
                for (const w of waiting.values()) w({ error: "worker error" });
                waiting.clear();
                post({ event: "ogg", msg: "worker failed: " + ((e && e.message) || "?") });
              };
            } catch (e) {
              workerBroken = true; worker = null;
              post({ event: "ogg", msg: "worker unavailable: " + ((e && e.message) || e) });
            }
            return worker;
          };
          const decodeInWorker = (bytes) => new Promise((resolve, reject) => {
            const w = getWorker();
            if (!w) return reject(new Error("no worker"));
            const id = nextId++;
            waiting.set(id, (d) => d.error ? reject(new Error(d.error)) : resolve(d));
            w.postMessage({ id, bytes: bytes.buffer }, [bytes.buffer]);
          });

          // 메인 스레드 (워커를 못 쓸 때만)
          let queue = Promise.resolve();
          const decodeOnMain = (bytes) => {
            const job = queue.then(async () => {
              const dec = new lib.OggVorbisDecoder();
              try {
                await dec.ready;
                const { channelData, samplesDecoded, sampleRate } = await dec.decodeFile(bytes);
                return { ch: channelData, samplesDecoded, sampleRate };
              } finally { try { dec.free(); } catch (e) {} }
            });
            queue = job.catch(() => {});
            return job;
          };

          // 기본 디코딩이 Ogg 를 푸는지: null 모름 · true 됨 · false 안 됨 (한 번 실패하면 다시 묻지 않는다)
          let native = null;
          const decodeOgg = async (ctx, orig, buf) => {
            const copy = buf.slice(0);   // 기본 디코딩이 buf 를 분리(detach)하므로 미리 복사
            if (native !== false) {
              try { const ab = await orig.call(ctx, buf); native = true; return ab; }
              catch (e) { if (native === null) { native = false; post({ event: "ogg", msg: "native decode unsupported" }); } }
            }
            const t0 = performance.now();
            let r, via = "worker";
            try { r = await decodeInWorker(new Uint8Array(copy.slice(0))); }
            catch (e) { via = "main"; r = await decodeOnMain(new Uint8Array(copy)); }
            if (!r.samplesDecoded) throw new Error("no samples");
            const ab = ctx.createBuffer(r.ch.length, r.samplesDecoded, r.sampleRate);
            r.ch.forEach((c, i) => ab.copyToChannel(c, i));
            post({ event: "ogg", msg: `decoded ${r.samplesDecoded} samples @${r.sampleRate} in ${(performance.now() - t0).toFixed(0)}ms (${via})` });
            return ab;
          };
          for (const C of [globalThis.AudioContext, globalThis.webkitAudioContext, globalThis.OfflineAudioContext]) {
            if (!C || !C.prototype || !C.prototype.decodeAudioData) continue;
            const orig = C.prototype.decodeAudioData;
            C.prototype.decodeAudioData = function (buf, ok, err) {
              if (!(buf instanceof ArrayBuffer) || buf.byteLength < 4 || !isOgg(buf)) return orig.call(this, buf, ok, err);
              const p = decodeOgg(this, orig, buf);
              if (ok || err) p.then(ok || (() => {}), err || (() => {}));
              return p;
            };
          }
        })();
        """
    }

    /// 포켓로그 음악 메모리 줄이기 (빌드 23). 큰 소리 파일(배경음악)만 24kHz 로 풀어 메모리를 절반 아래로 줄인다.
    /// 2026-11-01 아이패드 측정: 다 들은 배경음악이 메모리에서 거의 안 풀려 곡마다 40~80MB 씩 쌓였다(약 4시간에 1.25GB).
    /// 효과음은 작아서 그대로 둔다. 풀린 소리는 재생할 때 WebKit 이 기기 표본율로 바꿔 준다.
    /// 같은 곡을 다시 틀면 게임은 파일을 다시 받아 또 푸는데, 예전 것도 메모리에 남아 같은 곡이 여러 벌 쌓였다(2026-11-01 측정:
    /// town·metropolis 각 3벌). 그래서 아직 메모리에 있는 같은 주소의 곡은 새로 풀지 않고 그것을 다시 준다.
    /// AudioBuffer 는 재생 노드 여러 개가 함께 써도 되는 읽기 전용 데이터라 안전하다.
    /// 다른 소리 스크립트보다 먼저 넣어 가장 안쪽에서 돈다(Ogg 폴리필·효과음 이름 붙이기는 이 결과를 받는다)
    static func musicDiet(rate: Int) -> String {
        """
    (() => {
      let RATE = \(rate); const MIN_BYTES = 512 * 1024;
      const OAC = window.OfflineAudioContext || window.webkitOfflineAudioContext;
      if (!OAC || !OAC.prototype.decodeAudioData) return;
      const offDecode = OAC.prototype.decodeAudioData;
      const isWav = (buf) => { const u = new Uint8Array(buf, 0, 4); return u[0] === 0x52 && u[1] === 0x49 && u[2] === 0x46 && u[3] === 0x46; };
      // 받은 파일 → 주소. 게임의 onload(곧바로 디코딩)보다 먼저 돌도록 open 때 readystatechange 에 건다
      const urlOf = new WeakMap(), decoded = new Map();   // 주소 → WeakRef(AudioBuffer)
      const xo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, url) {
        this.__dietUrl = String(url);
        if (!this.__dietRS) { this.__dietRS = true; this.addEventListener("readystatechange", () => {
          try { if (this.readyState === 4 && this.responseType === "arraybuffer" && this.response) urlOf.set(this.response, this.__dietUrl.split("?")[0]); } catch (e) {}
        }); }
        return xo.apply(this, arguments);
      };
      try { const ra = Response.prototype.arrayBuffer; Response.prototype.arrayBuffer = function () { const u = String(this.url).split("?")[0]; return ra.call(this).then((b) => { try { urlOf.set(b, u); } catch (e) {} return b; }); }; } catch (e) {}
      const canReuse = typeof WeakRef === "function";
      let off = null;
      const lowRate = (buf) => new Promise((ok, err) => {
        if (!off) off = new OAC(2, 1, RATE);
        const r = offDecode.call(off, buf, ok, err);
        if (r && typeof r.then === "function") r.then(ok, err);
      });
      for (const name of ["AudioContext", "webkitAudioContext"]) {
        const C = window[name]; if (!C || !C.prototype.decodeAudioData) continue;
        const orig = C.prototype.decodeAudioData;
        C.prototype.decodeAudioData = function (buf, ok, err) {
          // 효과음(WAV, "RIFF")은 길이가 길어도 그대로 둔다: 포켓로그 배경음악은 mp3
          if (!(buf instanceof ArrayBuffer) || buf.byteLength < MIN_BYTES || isWav(buf)) return orig.call(this, buf, ok, err);
          const url = urlOf.get(buf);
          const prev = canReuse && url && decoded.get(url) && decoded.get(url).deref();
          let p;
          if (prev) { p = Promise.resolve(prev); }
          else {
            const copy = buf.slice(0);   // 낮은 표본율로 못 풀면 원래대로 다시 푼다 (디코딩이 buf 를 분리하므로 미리 복사)
            // 원음(기기 표본율 이상)이면 낮추지 않고 그대로 푼다. 같은 곡 다시 쓰기는 똑같이 한다
            p = this.sampleRate > RATE ? lowRate(buf).catch(() => orig.call(this, copy)) : orig.call(this, buf);
            if (canReuse && url) p.then((ab) => { if (ab) decoded.set(url, new WeakRef(ab)); }, () => {});
          }
          if (ok || err) p.then(ok || (() => {}), err || (() => {}));
          return p;
        };
      }
      // 일시정지 화면에서 음질을 바꾸면: 새로 푸는 곡부터 적용. 예전 표본율로 풀어 둔 곡은 다시 쓰지 않는다
      window.__bingsuMusicRate = (n) => { const v = Number(n); if (v >= 8000 && v <= 96000) { RATE = v; off = null; decoded.clear(); } };
    })();
    """
    }

    /// 포켓로그 소리 파일 저장 (2026-11-01). WebKit 은 XHR 로 받은 오디오 형식(audio/mpeg·audio/x-m4a) 응답을
    /// 스트리밍으로 보고 HTTP 캐시에 넣지 않는다. 그래서 들었던 배경음악도 매번 서버에서 다시 받아 로딩이 길어졌다
    /// (iPad 측정: battle_trainer.mp3 2.6MB 에 34초, 캐시에 mp3·m4a 0개, wav 418개). 서버는 10년 캐시를 허락한다.
    /// 같은 출처 /audio/ 아래 mp3·m4a·ogg 를 처음 받을 때 Cache API 에 복사해 두고, 다음부터는 XHR 을 보내지 않고
    /// 저장한 것으로 완료 이벤트를 흉내 낸다. 주소의 ?t= 가 게임 판이라 판이 바뀌면 새로 받고 예전 판은 지운다.
    /// 다른 소리 스크립트(musicDiet·sfxWatch)는 readyState 4 의 readystatechange 에서 응답을 읽으므로 그 순서를 지킨다.
    /// 끄면 저장한 것을 지운다(네이티브도 WKWebsiteDataTypeFetchCache 를 지움). `__bingsuAudioCache(true|false)`
    static func audioCache(on: Bool) -> String {
        """
    (() => {
      let ON = \(on ? "true" : "false");
      const NAME = "bingsu-audio-v1", EXT = /\\.(mp3|m4a|ogg|aac|flac)$/i;
      const dbg = (m) => { try { window.webkit.messageHandlers.diag.postMessage("acache " + m); } catch (e) {} };
      if (typeof caches === "undefined" || !window.XMLHttpRequest) { dbg("unavailable"); return; }
      let store = null;
      const open = () => store || (store = caches.open(NAME).catch((e) => { dbg("open failed " + e); store = null; return null; }));
      const audioURL = (m, u) => {
        if (String(m).toUpperCase() !== "GET") return null;
        try { const x = new URL(u, location.href); return x.origin === location.origin && x.pathname.startsWith("/audio/") && EXT.test(x.pathname) ? x.href : null; }
        catch (e) { return null; }
      };
      const X = XMLHttpRequest.prototype, xo = X.open, xs = X.send, xa = X.abort;
      X.open = function (m, u) {
        this.__acUrl = ON ? audioURL(m, u) : null; this.__acAborted = false; this.__acServed = false;
        if (this.__acUrl && !this.__acHooked) {
          this.__acHooked = true;
          // 처음 받은 것을 저장. 게임의 onload(곧바로 디코딩해 버퍼를 분리)보다 먼저 도는 readystatechange 에서 복사한다
          this.addEventListener("readystatechange", () => {
            if (this.readyState !== 4 || !this.__acUrl || this.__acServed || this.status !== 200 || this.responseType !== "arraybuffer") return;
            const buf = this.response; if (!(buf instanceof ArrayBuffer) || !buf.byteLength) return;
            const url = this.__acUrl, copy = buf.slice(0), type = this.getResponseHeader("content-type") || "application/octet-stream";
            open().then((c) => {
              if (!c || !ON) return;
              const bare = url.split("?")[0];
              return c.delete(bare, { ignoreSearch: true })   // 예전 판(다른 ?t=)은 지운다
                .then(() => c.put(url, new Response(copy, { headers: { "content-type": type, "content-length": String(copy.byteLength) } })))
                .then(() => dbg("stored " + bare.split("/audio/")[1] + " " + (copy.byteLength >> 10) + "KB"));
            }).catch((e) => dbg("store failed " + e));
          });
        }
        return xo.apply(this, arguments);
      };
      const finish = (xhr, buf, type, url) => {
        const def = (k, v) => Object.defineProperty(xhr, k, { value: v, configurable: true });
        def("readyState", 4); def("status", 200); def("statusText", "OK"); def("response", buf); def("responseURL", url);
        def("getResponseHeader", (h) => { const k = String(h).toLowerCase(); return k === "content-type" ? type : k === "content-length" ? String(buf.byteLength) : null; });
        def("getAllResponseHeaders", () => "content-type: " + type + "\\r\\ncontent-length: " + buf.byteLength + "\\r\\n");
        const pe = (t) => new ProgressEvent(t, { lengthComputable: true, loaded: buf.byteLength, total: buf.byteLength });
        xhr.dispatchEvent(new Event("readystatechange"));
        xhr.dispatchEvent(pe("progress")); xhr.dispatchEvent(pe("load")); xhr.dispatchEvent(pe("loadend"));
      };
      X.send = function () {
        const url = this.__acUrl, args = arguments;
        if (!url || !ON || this.responseType !== "arraybuffer") return xs.apply(this, args);
        const t0 = performance.now();
        open().then((c) => c ? c.match(url) : null).then((r) => {
          if (this.__acAborted) return;
          if (!r) { xs.apply(this, args); return; }
          const type = r.headers.get("content-type") || "application/octet-stream";
          return r.arrayBuffer().then((buf) => {
            if (this.__acAborted) return;
            this.__acServed = true;
            dbg("hit " + url.split("?")[0].split("/audio/")[1] + " " + (buf.byteLength >> 10) + "KB " + (performance.now() - t0).toFixed(0) + "ms");
            finish(this, buf, type, url);
          });
        }).catch((e) => { dbg("read failed " + e); if (!this.__acAborted && !this.__acServed) { try { xs.apply(this, args); } catch (x) {} } });
      };
      X.abort = function () { this.__acAborted = true; return xa.apply(this, arguments); };
      window.__bingsuAudioCache = (v) => { ON = !!v; if (!ON) { store = null; caches.delete(NAME).catch(() => {}); } };
      if (!ON) { caches.delete(NAME).catch(() => {}); return; }
      // 디버그: 시작할 때 저장된 수와 용량
      open().then((c) => c && c.keys()).then((k) => {
        const est = navigator.storage && navigator.storage.estimate ? navigator.storage.estimate() : Promise.resolve({});
        return est.then((e) => dbg("on entries=" + (k ? k.length : 0) + " usage=" + ((e.usage || 0) / 1048576).toFixed(0) + "MB quota=" + ((e.quota || 0) / 1048576).toFixed(0) + "MB"));
      }).catch(() => {});
    })();
    """
    }

    /// 무음 모드에서도 소리 재생. WebKit 은 Web Audio 만 쓰는 페이지를 "ambient"(무음 스위치를 따름)로 다룬다.
    /// 1) Audio Session API 로 분류를 playback 으로, 2) 그것만으로 안 되는 기기(iPad 포켓로그, 2026-10-31)를 위해
    /// 아무 소리 없는 <audio> 를 반복 재생해 WebKit 이 페이지를 미디어 재생으로 보게 한다. 끄면 둘 다 되돌린다.
    /// 네이티브가 설정을 바꾸면 `__bingsuSilentMode(true|false)` 를 부른다
    static func silentMode(playInSilent: Bool) -> String {
        """
        (() => {
          const post = (m) => { try { window.webkit.messageHandlers.bowl.postMessage({ event: "audio", msg: m }); } catch (e) {} };
          let on = \(playInSilent ? "true" : "false"), held = false, el = null, url = null;
          // 0.5초짜리 8kHz 8비트 무음 WAV (0x80 = 무음)
          const silentURL = () => {
            if (url) return url;
            const n = 4000, b = new Uint8Array(44 + n), v = new DataView(b.buffer);
            const tag = (o, t) => { for (let i = 0; i < 4; i++) b[o + i] = t.charCodeAt(i); };
            tag(0, "RIFF"); v.setUint32(4, 36 + n, true); tag(8, "WAVE"); tag(12, "fmt ");
            v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
            v.setUint32(24, 8000, true); v.setUint32(28, 8000, true); v.setUint16(32, 1, true); v.setUint16(34, 8, true);
            tag(36, "data"); v.setUint32(40, n, true); b.fill(0x80, 44);
            try { url = URL.createObjectURL(new Blob([b], { type: "audio/wav" })); }
            catch (e) { let s = ""; for (const x of b) s += String.fromCharCode(x); url = "data:audio/wav;base64," + btoa(s); }
            return url;
          };
          const keep = () => {
            if (!on || held || document.hidden) { if (el) el.pause(); return; }
            if (!el) {
              el = document.createElement("audio");
              el.loop = true; el.preload = "auto"; el.setAttribute("playsinline", ""); el.setAttribute("x-webkit-airplay", "deny");
              el.src = silentURL();
            }
            const p = el.play(); if (p && p.catch) p.catch((e) => post("silent keep failed " + e));
          };
          const apply = (v) => {
            on = !!v;
            try { if (navigator.audioSession) navigator.audioSession.type = on ? "playback" : "ambient"; } catch (e) {}
            keep();
            post("session " + (navigator.audioSession ? navigator.audioSession.type : "none") + " keep=" + on);
          };
          window.__bingsuSilentMode = apply;
          // 네이티브: 게임이 안 보이거나(홈·다른 앱) 일시정지면 true. 무음 재생이 백그라운드 소리를 살려 두지 않게
          window.__bingsuSilentHold = (h) => { held = !!h; keep(); };
          try { if (navigator.audioSession) navigator.audioSession.type = on ? "playback" : "ambient"; } catch (e) {}
          // 페이지가 뜬 뒤 무음 <audio> 시작, 첫 터치·키에서 한 번 더 (자동 재생이 막힌 경우), 다시 보일 때 다시
          document.addEventListener("DOMContentLoaded", () => apply(on), { once: true });
          for (const t of ["pointerdown", "touchend", "keydown"]) window.addEventListener(t, keep, { once: true, capture: true });
          document.addEventListener("visibilitychange", keep);
        })();
        """
    }

    /// 효과음 감시: 게임이 어떤 소리 파일을 재생하는지 알아내 네이티브로 알린다 (컨트롤러 진동용).
    /// XHR 로 받은 ArrayBuffer → 파일 경로, decodeAudioData 결과 AudioBuffer → 파일 경로를 이어 두고,
    /// AudioBufferSourceNode.start 때 그 경로의 파일 이름만 보낸다 (URL 전체·쿼리는 보내지 않음).
    static let sfxWatch = """
    (() => {
      const post = (b) => { try { window.webkit.messageHandlers.sfx.postMessage(b); } catch (e) {} };
      const dbg = (m) => { if (window.__bingsuKeyDebug) { try { window.webkit.messageHandlers.bowl.postMessage({ event: "sfxdbg", msg: m }); } catch (e) {} } };
      const AUDIO = /\\.(wav|ogg|mp3|m4a|aac|flac|opus|webm)(\\?|$)/i;
      const nameOf = (url) => { try { const p = String(url).split("?")[0].split("#")[0]; return decodeURIComponent(p.split("/").pop() || ""); } catch (e) { return ""; } };
      const byArray = new WeakMap();   // ArrayBuffer → 파일 이름
      const byLength = new Map();      // 바이트 길이 → 파일 이름 (복사된 버퍼 대비, 길이가 겹치면 지움)
      const byAudio = new WeakMap();   // AudioBuffer → 파일 이름
      const remember = (buf, url) => {
        if (!(buf instanceof ArrayBuffer) || !AUDIO.test(String(url))) return;
        const n = nameOf(url); if (!n) return;
        dbg("remember " + n + " " + buf.byteLength);
        byArray.set(buf, n);
        if (byLength.has(buf.byteLength) && byLength.get(buf.byteLength) !== n) byLength.set(buf.byteLength, null);
        else byLength.set(buf.byteLength, n);
      };
      // XHR (Phaser 오디오 로더)
      try {
        // 게임의 onload 보다 먼저 돌도록 open() 때 readystatechange 리스너를 건다 (리스너는 등록 순서대로 실행)
        const open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (m, url, ...rest) {
          if (!this.__bingsuHooked) {
            this.__bingsuHooked = true;
            this.addEventListener("readystatechange", () => {
              try { if (this.readyState === 4 && this.responseType === "arraybuffer") remember(this.response, this.__bingsuUrl); } catch (e) {}
            });
          }
          this.__bingsuUrl = url;
          return open.call(this, m, url, ...rest);
        };
      } catch (e) {}
      // fetch(...).arrayBuffer()
      try {
        const of = window.fetch;
        window.fetch = function (input, init) {
          const url = typeof input === "string" ? input : (input && input.url) || "";
          const p = of.call(this, input, init);
          if (!AUDIO.test(url)) return p;
          return p.then((r) => {
            try { const ab = r.arrayBuffer.bind(r); r.arrayBuffer = () => ab().then((b) => { remember(b, url); return b; }); } catch (e) {}
            return r;
          });
        };
      } catch (e) {}
      // decodeAudioData: 들어온 ArrayBuffer 의 이름을 결과 AudioBuffer 에 붙인다
      for (const C of [globalThis.AudioContext, globalThis.webkitAudioContext, globalThis.OfflineAudioContext]) {
        if (!C || !C.prototype || !C.prototype.decodeAudioData) continue;
        const orig = C.prototype.decodeAudioData;
        C.prototype.decodeAudioData = function (buf, ok, err) {
          let n = null;
          try { n = (buf instanceof ArrayBuffer && (byArray.get(buf) || byLength.get(buf.byteLength))) || null; } catch (e) {}
          dbg("decode " + (n || "?") + " len=" + (buf && buf.byteLength));
          const tag = (ab) => { if (n && ab) { try { byAudio.set(ab, n); } catch (e) {} } return ab; };
          const r = orig.call(this, buf, ok ? (ab) => ok(tag(ab)) : undefined, err);
          return r && typeof r.then === "function" ? r.then(tag) : r;
        };
      }
      // 재생 시작
      try {
        const S = globalThis.AudioBufferSourceNode;
        const start = S.prototype.start;
        let lastName = "", lastAt = 0;
        S.prototype.start = function (...a) {
          try {
            const n = this.buffer && byAudio.get(this.buffer);
            const now = performance.now();
            if (!n) dbg("start untagged len=" + (this.buffer && this.buffer.length));
            if (n && !(n === lastName && now - lastAt < 40)) { lastName = n; lastAt = now; post({ name: n.slice(0, 80) }); }
          } catch (e) {}
          return start.apply(this, a);
        };
      } catch (e) {}
    })();
    """

    /// 포켓로그: 자체 터치 컨트롤은 숨기고, 빙수 가상 패드 입력을 그 숨겨진 버튼([data-key])의 pointer 리스너로 넣는다.
    /// 포켓로그는 키보드 이벤트 대신 이 경로로 Phaser 게임 이벤트("input_down")를 직접 쏘므로 가장 확실하다.
    static let pokerogueBridge = """
    (() => {
      const s = document.createElement("style");
      s.textContent = "#touchControls{display:none!important}";
      (document.head || document.documentElement).appendChild(s);
      // KeyboardEvent.code → 포켓로그 Button 이름 (data-key)
      const MAP = { ArrowUp: "UP", ArrowDown: "DOWN", ArrowLeft: "LEFT", ArrowRight: "RIGHT",
                    KeyZ: "ACTION", Space: "ACTION", KeyX: "CANCEL", Backspace: "CANCEL",
                    KeyC: "STATS", ShiftLeft: "STATS", Escape: "MENU", KeyM: "MENU", Enter: "SUBMIT",
                    KeyR: "CYCLE_SHINY", KeyF: "CYCLE_FORM", KeyG: "CYCLE_GENDER", KeyE: "CYCLE_ABILITY",
                    KeyN: "CYCLE_NATURE", KeyV: "CYCLE_TERA", PageUp: "SPEED_UP", PageDown: "SLOW_DOWN" };
      const held = {};
      const post = (n, b) => { try { window.webkit.messageHandlers[n].postMessage(b); } catch (e) {} };
      const fire = (el, type) => el.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerType: "touch", isPrimary: true }));
      const orig = window.__bingsu && window.__bingsu.key;
      const press = (code, down) => {
        const name = MAP[code];
        const el = name && document.querySelector('[data-key="' + name + '"]');
        if (window.__bingsuKeyDebug) post("bowl", { event: "prkey", msg: code + " → " + name + " el=" + (el ? el.id : "none") + " down=" + down });
        if (!el) { if (orig) orig(code, down); return; }
        if (down) { if (held[code]) return; held[code] = el; fire(el, "pointerdown");
          if (window.__bingsuKeyDebug) post("bowl", { event: "prkey", msg: "after down active=" + el.classList.contains("active") + " tc=" + (document.getElementById("touchControls") || {}).className + " ds=" + JSON.stringify(document.documentElement.dataset) }); }
        else { const h = held[code]; delete held[code]; if (h) fire(h, "pointerup"); }
      };
      const install = () => { if (window.__bingsu) window.__bingsu.key = press; };
      install(); document.addEventListener("DOMContentLoaded", install);
    })();
    """

    #if DEBUG
    /// 디버그 빌드 전용 측정 (DiagLog 로 감). 멈춤마다 그 사이 받은 파일·메인 스레드 막힘·디코딩을, 15초마다 메모리 짐작 수치를 보낸다.
    /// 주소는 경로만(쿼리 없음) 보낸다: 로그인 토큰이 기록에 남지 않게
    static let diag = """
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.diag.postMessage(String(m).slice(0, 600)); } catch (e) {} };
      const path = (u) => { try { const x = new URL(u, location.href); return (x.host === location.host ? "" : x.host) + x.pathname.slice(-70); } catch (e) { return "?"; } };
      // 그림 종류: 이미지는 주소의 폴더 두 단계(images/pokemon 등), 캔버스는 글자·그림을 그린 것
      const dirOf = (u) => { try { const parts = new URL(u, location.href).pathname.split("/").filter(Boolean); return parts.slice(0, Math.min(3, parts.length - 1)).join("/") || "root"; } catch (e) { return "?"; } };
      // 게임이 XHR 로 받은 그림을 blob: 주소로 바꿔 쓰므로, blob 주소 → 원래 주소를 기억해 둔다
      const blobFrom = new WeakMap(), blobSrc = new Map();
      const cou = URL.createObjectURL;
      URL.createObjectURL = function (o) { const u = cou.call(URL, o); const from = o && blobFrom.get(o); if (from) { blobSrc.set(u, from); if (blobSrc.size > 5000) blobSrc.clear(); } return u; };
      try { const ra = Response.prototype.arrayBuffer; Response.prototype.arrayBuffer = function () { const u = this.url; return ra.call(this).then((b) => { try { abFrom.set(b, path(u)); } catch (e) {} return b; }); }; } catch (e) {}
      try { const rb = Response.prototype.blob; Response.prototype.blob = function () { const u = this.url; return rb.call(this).then((b) => { try { blobFrom.set(b, u); } catch (e) {} return b; }); }; } catch (e) {}
      const kindOf = (s) => {
        if (!s) return "raw";
        if (s instanceof HTMLCanvasElement) return "canvas";
        if (s instanceof HTMLVideoElement) return "video";
        const src = s.currentSrc || s.src;
        if (!src) return s.constructor ? s.constructor.name : "?";
        if (src.startsWith("data:")) return "data-url";
        if (src.startsWith("blob:")) { const o = blobSrc.get(src); return o ? dirOf(o) : "blob"; }
        return dirOf(src);
      };
      // WebGL 텍스처: 만든 것·지운 것·올린 크기 (게임이 그림을 안 지우고 쌓는지)
      const tex = new Map(); let texBytes = 0, texMade = 0, texGone = 0; const bound = new WeakMap(), unitOf = new WeakMap();
      for (const C of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
        if (!C) continue; const p = C.prototype;
        const cT = p.createTexture, dT = p.deleteTexture, bT = p.bindTexture, tI = p.texImage2D, aT = p.activeTexture;
        // 텍스처 유닛마다 따로 묶이므로 유닛별로 기억한다 (마지막 것만 보면 다른 유닛의 업로드를 엉뚱한 텍스처에 셈)
        p.activeTexture = function (u) { unitOf.set(this, u); return aT.call(this, u); };
        p.createTexture = function () { const t = cT.call(this); if (t) { tex.set(t, { b: 0, k: "empty" }); texMade++; } return t; };
        p.deleteTexture = function (t) { if (t && tex.has(t)) { texBytes -= tex.get(t).b; tex.delete(t); texGone++; } return dT.call(this, t); };
        p.bindTexture = function (target, t) {
          if (target === this.TEXTURE_2D) { let m = bound.get(this); if (!m) { m = new Map(); bound.set(this, m); } m.set(unitOf.get(this) || this.TEXTURE0, t); }
          return bT.call(this, target, t);
        };
        p.texImage2D = function (...a) {
          try {
            const m = bound.get(this), t = m && m.get(unitOf.get(this) || this.TEXTURE0);
            if (a[0] === this.TEXTURE_2D && a[1] === 0 && t && tex.has(t)) {
              let w = 0, h = 0, k = "raw";
              if (a.length >= 8) { w = a[3]; h = a[4]; k = "raw:" + w + "x" + h; } else {
                const s = a[5]; w = (s && (s.naturalWidth || s.videoWidth || s.width)) || 0; h = (s && (s.naturalHeight || s.videoHeight || s.height)) || 0;
                k = kindOf(s);
              }
              const b = w * h * 4; texBytes += b - tex.get(t).b; tex.set(t, { b, k });
            }
          } catch (e) {}
          return tI.apply(this, a);
        };
      }
      // 오디오 디코딩: 횟수·디코딩된 크기(누적)·최근 디코딩 시간
      let decN = 0, decBytes = 0, liveN = 0, liveBytes = 0; const decLog = [];
      // 아직 버려지지 않은(가비지 컬렉션 안 된) 디코딩 결과
      // 곡별: 아직 살아 있는 디코딩 결과의 이름·크기·표본율 (받은 ArrayBuffer → 주소로 이름을 찾는다)
      const abFrom = new WeakMap(), live = new Map(); let liveId = 0;
      const gone = typeof FinalizationRegistry === "function" ? new FinalizationRegistry((id) => { const x = live.get(id); if (x) { liveN--; liveBytes -= x.b; live.delete(id); } }) : null;
      for (const name of ["AudioContext", "webkitAudioContext"]) {
        const C = window[name]; if (!C || !C.prototype.decodeAudioData) continue;
        const orig = C.prototype.decodeAudioData;
        C.prototype.decodeAudioData = function (buf, ok, err) {
          const t0 = performance.now(), size = buf && buf.byteLength || 0;
          let src = "?"; try { src = (buf && abFrom.get(buf)) || "?"; } catch (e) {}
          const done = (ab) => { if (!ab || ab.__diag) return; ab.__diag = 1; const b = ab.length * ab.numberOfChannels * 4; decN++; decBytes += b;
                                 if (gone) { const id = ++liveId; live.set(id, { n: src, b, r: ab.sampleRate, at: performance.now() }); liveN++; liveBytes += b; gone.register(ab, id); }
                                 decLog.push({ at: performance.now(), ms: performance.now() - t0, kb: size >> 10 }); if (decLog.length > 50) decLog.shift(); };
          const r = orig.call(this, buf, ok ? (ab) => { done(ab); ok(ab); } : undefined, err);
          if (r && typeof r.then === "function") r.then(done, () => {});
          return r;
        };
      }
      // 받은 파일 (최근 것만 보관)
      const res = []; let resN = 0, resBytes = 0;
      try { performance.setResourceTimingBufferSize(500); } catch (e) {}
      try {
        new PerformanceObserver((list) => {
          for (const e of list.getEntries()) {
            resN++; resBytes += e.transferSize || 0;
            res.push({ s: e.startTime, e: e.responseEnd, p: path(e.name), kb: (e.transferSize || 0) >> 10, k: e.initiatorType });
            // 처음 불러오기(30초)는 빼고 오래 걸린 파일만
            if (e.duration > 1500 && performance.now() > 30000) post("slow " + e.duration.toFixed(0) + "ms " + e.initiatorType + " " + path(e.name) + " " + ((e.transferSize || 0) >> 10) + "KB");
          }
          if (res.length > 300) res.splice(0, res.length - 300);
          try { performance.clearResourceTimings(); } catch (e) {}
        }).observe({ type: "resource", buffered: true });
      } catch (e) { post("no resource observer " + e); }
      // 아직 안 끝난 요청 (끝난 것만 남는 resource 기록으로는 "응답이 안 와서 계속 로딩" 이 안 보인다)
      const pending = new Map(); let reqId = 0, reqFail = 0;
      const reqStart = (method, url) => { const id = ++reqId; pending.set(id, { m: method, p: path(url), t: performance.now() }); return id; };
      const reqEnd = (id, how) => {
        const r = pending.get(id); if (!r) return; pending.delete(id);
        const ms = performance.now() - r.t;
        if (how !== "ok") reqFail++;
        if (how !== "ok" || ms > 3000) post("req " + how + " " + ms.toFixed(0) + "ms " + r.m + " " + r.p);
      };
      const fetchOrig = window.fetch;
      if (fetchOrig) window.fetch = function (input, init) {
        const url = typeof input === "string" ? input : (input && input.url) || String(input);
        const method = (init && init.method) || (input && input.method) || "GET";
        const id = reqStart(method, url);
        return fetchOrig.apply(this, arguments).then((r) => { reqEnd(id, r.ok ? "ok" : "http" + r.status); return r; },
                                                     (e) => { reqEnd(id, "fail:" + ((e && e.name) || e)); throw e; });
      };
      const xo = XMLHttpRequest.prototype.open, xs = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__diagReq = [method, url];
        // 소리 이름: 게임의 onload(곧바로 디코딩)보다 먼저 돌도록 open 때 readystatechange 에 건다 (loadend 는 onload 뒤라 늦다)
        if (!this.__diagRS) { this.__diagRS = true; this.addEventListener("readystatechange", () => {
          try { if (this.readyState === 4 && this.responseType === "arraybuffer" && this.response) abFrom.set(this.response, path(this.__diagReq[1])); } catch (e) {}
        }); }
        return xo.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        const [method, url] = this.__diagReq || ["?", "?"]; const id = reqStart("xhr " + method, url);
        this.addEventListener("loadend", () => {
          reqEnd(id, this.status >= 200 && this.status < 400 ? "ok" : "xhr" + this.status);
          try { if (this.responseType === "blob" && this.response) blobFrom.set(this.response, url); } catch (e) {}
        });
        return xs.apply(this, arguments);
      };
      setInterval(() => {
        const now = performance.now();
        const old = Array.from(pending.values()).filter((r) => now - r.t > 5000);
        if (old.length) post("WAITING " + old.length + " [" + old.slice(0, 6).map((r) => r.m + " " + r.p + " " + ((now - r.t) / 1000).toFixed(0) + "s").join(", ") + "]");
      }, 5000);
      // 메인 스레드 막힘: 100ms 타이머가 늦게 온 만큼
      const blocks = []; let hbLast = performance.now();
      setInterval(() => { const now = performance.now(), gap = now - hbLast; hbLast = now;
        if (gap > 350 && !document.hidden) { blocks.push({ at: now, ms: gap - 100 }); if (blocks.length > 50) blocks.shift(); } }, 100);
      // 화면 멈춤: 0.3초 넘게 프레임이 안 온 때, 그 사이에 있었던 일
      let last = performance.now(), frames = 0, stalls = 0, hiddenAt = 0;
      document.addEventListener("visibilitychange", () => { hiddenAt = performance.now(); post("visible " + !document.hidden); });
      const tick = (t) => {
        const d = t - last; last = t; frames++;
        if (d > 300 && !document.hidden && t - hiddenAt > 1000) {
          stalls++;
          const from = t - d - 200;
          const r = res.filter((x) => x.e >= from || x.s >= from);
          const b = blocks.filter((x) => x.at >= from).reduce((a, x) => a + x.ms, 0);
          const dc = decLog.filter((x) => x.at >= from);
          post("STALL " + d.toFixed(0) + "ms block=" + b.toFixed(0) + "ms files=" + r.length + " [" + r.slice(-6).map((x) => x.p + ":" + x.kb + "KB/" + (x.e - x.s).toFixed(0) + "ms").join(", ") + "]"
               + " dec=" + dc.length + (dc.length ? "(" + dc.map((x) => x.kb + "KB/" + x.ms.toFixed(0)).slice(-4).join(",") + ")" : ""));
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      let lastStat = performance.now(), statN = 0;
      setInterval(() => {
        const now = performance.now(), fps = frames * 1000 / (now - lastStat); frames = 0; lastStat = now;
        let nodes = -1; try { nodes = document.getElementsByTagName("*").length; } catch (e) {}
        post("stat fps=" + fps.toFixed(1) + " stalls=" + stalls + " tex=" + tex.size + "(" + (texBytes / 1048576).toFixed(0) + "MB +" + texMade + "/-" + texGone + ")"
             + " dec=" + decN + "(" + (decBytes / 1048576).toFixed(0) + "MB) audioLive=" + liveN + "(" + (liveBytes / 1048576).toFixed(0) + "MB)" + " files=" + resN + "(" + (resBytes / 1048576).toFixed(1) + "MB)"
             + " dom=" + nodes + " canvas=" + document.getElementsByTagName("canvas").length + " audio=" + document.getElementsByTagName("audio").length
             + " pending=" + pending.size + " reqFail=" + reqFail + (navigator.onLine ? "" : " OFFLINE"));
        stalls = 0;
        if (++statN % 4 === 1) {
          const mix = new Map();
          for (const v of tex.values()) { const m = mix.get(v.k) || { n: 0, b: 0 }; m.n++; m.b += v.b; mix.set(v.k, m); }
          const byDir = new Map();
          for (const x of live.values()) { const d = x.n.split("/").slice(0, 3).join("/"); const m = byDir.get(d) || { n: 0, b: 0 }; m.n++; m.b += x.b; byDir.set(d, m); }
          post("audiomix " + Array.from(byDir.entries()).sort((a, b) => b[1].b - a[1].b).slice(0, 8).map(([k, m]) => k + "=" + m.n + "/" + (m.b / 1048576).toFixed(0) + "MB").join(" "));
          post("audiotop " + Array.from(live.values()).sort((a, b) => b.b - a.b).slice(0, 12)
               .map((x) => x.n.split("/").pop() + ":" + (x.b / 1048576).toFixed(0) + "MB@" + (x.r / 1000).toFixed(0) + "k/" + ((performance.now() - x.at) / 60000).toFixed(0) + "m").join(" "));
          post("texmix " + Array.from(mix.entries()).sort((a, b) => b[1].b - a[1].b).slice(0, 12)
               .map(([k, m]) => k + "=" + m.n + "/" + (m.b / 1048576).toFixed(1) + "MB").join(" "));
        }
      }, 15000);
      window.addEventListener("error", (e) => post("error " + e.message + " @" + path(e.filename || "") + ":" + e.lineno));
      window.addEventListener("unhandledrejection", (e) => post("rejection " + String(e.reason && (e.reason.message || e.reason)).slice(0, 200)));
      post("diag ready dpr=" + devicePixelRatio + " " + innerWidth + "x" + innerHeight);
    })();
    """
    #endif

    /// 전체화면·터치 보정 CSS (웹 게임용)
    static let fullscreenCSS = """
    (() => {
      const s = document.createElement("style");
      s.textContent = "html,body{overscroll-behavior:none;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent}";
      (document.head || document.documentElement).appendChild(s);
      let vp = document.querySelector('meta[name=viewport]');
      if (!vp) { vp = document.createElement('meta'); vp.name = 'viewport'; document.head.appendChild(vp); }
      vp.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
    })();
    """

    private static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let arr = String(data: data, encoding: .utf8)!
        return String(arr.dropFirst().dropLast())
    }
}
