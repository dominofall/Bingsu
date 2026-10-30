import Foundation

/// 유리그릇에 주입하는 JS. 세 가지 일만 한다:
/// 1. 냉동실: localStorage 스냅샷 복원 / 주기 전송   2. 온도계: rAF 프레임 측정   3. 숟가락: KeyboardEvent 합성
enum BowlScripts {
    /// 문서 시작 전: 냉동실 복원 + 공용 브리지
    /// `freezer == false`(원격 웹 게임)면 localStorage 를 읽지도, 파일로 보내지도 않는다 — 로그인 토큰이 파일로 새는 것을 막기 위해.
    static func atDocumentStart(restore: Freezer.Snapshot?, keyPrefix: String, freezer: Bool, desktopSpoof: Bool,
                                renderScale: Double? = nil, fpsCap: Int? = nil) -> String {
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
              const target = document.activeElement && document.activeElement !== document.body ? document.activeElement : window;
              target.dispatchEvent(ev);
              if (down && window.__bingsuKeyDebug) post("bowl", { event: "key", msg: code + " keyCode=" + ev.keyCode + " prevented=" + ev.defaultPrevented + " target=" + (target === window ? "window" : target.tagName) });
            },
            flush, pause, resume, kickAudio, restartAudio, setFpsCap,
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
