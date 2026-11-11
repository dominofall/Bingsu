import Foundation

extension BowlScripts {
    /// RPG Maker MV·MZ 용 NW.js 흉내 (문서 시작, `.rpgMakerMV` 만). 명세 docs/engines/IMPLEMENTATION-mvmz.md §3.
    ///
    /// 엔진은 `typeof require === "function" && typeof process === "object"` 면 NW.js(PC)로 보고 `save/` 에 파일로 저장한다.
    /// 그 파일 읽기·쓰기를 같은 출처(`bingsu-mv://game`)로 보내는 **동기 XHR** 로 바꾸고, 스킴 핸들러(GreenTeaSchemeHandler)가
    /// `save/` 아래 정해진 이름만 저장 데이터 폴더에 쓴다. 그 밖의 쓰기는 403 → 여기서 EACCES 오류로 바뀐다.
    /// `require` 는 fs·path·os·nw.gui 만 준다. 창·메뉴·개발자 도구는 아무것도 안 하는 객체, 종료·외부 링크는 네이티브(`mv` 메시지)로.
    /// 경로는 게임 루트를 `/` 로 둔다 (MZ main.js 는 `/private/var` 로 시작하는 경로를 막는다).
    static func nwShim(engine: MVMZInfo.Engine) -> String {
        """
        (() => {
        \(nodeKit)
          const ENGINE = "\(engine.rawValue)";
          const ORIGIN = "\(GreenTeaSchemeHandler.origin)";
          const post = (body) => { try { window.webkit.messageHandlers.bowl.postMessage(body); } catch (e) {} };
          const native = (body) => { try { window.webkit.messageHandlers.mv.postMessage(body); } catch (e) {} };
          const log = (msg) => post({ event: "mv", msg: String(msg) });
          const noop = () => {};
          const quit = () => { log("quit"); native({ op: "quit" }); };

          // ---- path·Buffer·fs·os: Node 흉내 공용 부품 (BowlScripts.nodeKit, 게임 루트 = "/") ----
          const kit = makeNodeKit({ origin: ORIGIN, cwd: "/", log, compat: (what, file) => log("compat " + what + (file ? " @" + file : "")) });
          const { path, Buf, fs, os } = kit;
          if (typeof window.Buffer === "undefined") try { Object.defineProperty(window, "Buffer", { configurable: true, writable: true, value: Buf }); } catch (e) {}

          // ---- process ----
          const proc = {
            platform: "linux", arch: "arm64", env: {}, argv: [], execArgv: [], execPath: "/", version: "", versions: {}, title: "", pid: 1,
            cwd: () => "/", chdir: noop, exit: quit, on: noop, once: noop, off: noop, removeListener: noop, removeAllListeners: noop, emit: noop,
            nextTick: (fn, ...a) => Promise.resolve().then(() => fn(...a)),
            hrtime: (prev) => { const t = performance.now(), s = Math.floor(t / 1000), n = Math.floor((t % 1000) * 1e6); return prev ? [s - prev[0], n - prev[1]] : [s, n]; },
            memoryUsage: () => ({ rss: 0, heapTotal: 0, heapUsed: 0, external: 0 }),
            mainModule: { filename: "/index.html" },
          };

          // ---- nw.gui ----
          const winBase = { get width() { return innerWidth; }, get height() { return innerHeight; }, x: 0, y: 0, isFullscreen: true,
                            isKioskMode: false, isTransparent: false, zoomLevel: 0, menu: null, window };
          const win = new Proxy(winBase, {
            get: (t, k) => {
              if (k in t) return t[k];
              if (typeof k === "symbol" || k === "then" || k === "toJSON") return undefined;
              return (...a) => { if (k === "close") quit(); return win; };
            },
            set: (t, k, v) => { t[k] = v; return true; },
          });
          class Menu { constructor() { this.items = []; } append(i) { this.items.push(i); } insert(i, n) { this.items.splice(n, 0, i); } remove() {} removeAt() {} popup() {} createMacBuiltin() {} }
          class MenuItem { constructor(o) { Object.assign(this, o || {}); } on() {} }
          const gui = {
            App: { quit, closeAllWindows: quit, argv: [], fullArgv: [], manifest: {}, dataPath: "/", clearCache: noop, on: noop, setCrashDumpDir: noop },
            Window: { get: () => win, open: () => win },
            Menu, MenuItem, Tray: class { remove() {} },
            Shell: { openExternal: (url) => { log("openExternal"); native({ op: "open", url: String(url) }); }, openItem: noop, showItemInFolder: noop },
            Screen: { Init: noop, screens: [], on: noop },
            Clipboard: { get: () => ({ get: () => "", set: noop, clear: noop }) },
          };

          // ---- require ----
          const modules = { fs, path, os, "nw.gui": gui };
          const asked = new Set();
          const require = function require(name) {
            const n = String(name).replace(/^node:/, "");
            const ok = Object.prototype.hasOwnProperty.call(modules, n);
            if (!asked.has(n)) { asked.add(n); log("require " + n + (ok ? "" : " missing")); }
            if (ok) return modules[n];
            const e = new Error("Cannot find module '" + n + "'"); e.code = "MODULE_NOT_FOUND"; throw e;
          };
          const def = (k, v) => { try { Object.defineProperty(window, k, { configurable: true, writable: true, value: v }); } catch (e) {} };
          def("require", require); def("process", proc);
          if (typeof window.nw === "undefined") def("nw", gui);
          window.close = quit;

          // ---- 엔진이 뜬 뒤: 소리 형식, 다시 불러오기, 진단 로그 ----
          let hooked = false;
          const afterEngine = () => {
            if (hooked || !window.SceneManager) return;
            hooked = true;
            // MZ 의 오류 화면 "다시 시도" 는 chrome.runtime.reload() 를 부른다 (NW.js 전용) → 그냥 새로고침
            try { SceneManager.reloadGame = () => location.reload(); } catch (e) {}
            let via = "-";
            try {
              if (ENGINE === "mv" && window.WebAudio) {
                // MV 는 canPlayType('audio/ogg') 가 빈 문자열이면 .m4a 를 찾는데 PC 판엔 .m4a 가 없는 일이 많다. 빙수 Ogg 폴리필이 푼다
                WebAudio.canPlayOgg = () => true; via = "polyfill";
              } else if (ENGINE === "mz" && window.Utils && Utils.canPlayOgg) {
                via = Utils.canPlayOgg() ? "native" : "vorbisdecoder";
              }
            } catch (e) {}
            let ext = ".ogg";
            try { if (window.AudioManager && AudioManager.audioFileExt) ext = AudioManager.audioFileExt(); } catch (e) {}
            log("audio ext=" + ext + " via=" + via);
            try { log("ua mobile=" + (window.Utils && Utils.isMobileDevice ? Utils.isMobileDevice() : "?") + " nwjs=" + (window.Utils && Utils.isNwjs ? Utils.isNwjs() : "?") + " " + navigator.userAgent); } catch (e) {}
          };
          document.addEventListener("DOMContentLoaded", afterEngine);
          window.addEventListener("load", afterEngine);

          // ---- 일시정지에서 돌아올 때: 멈춘 동안의 시간을 따라잡으려고 한 프레임에 여러 번 갱신하지 않게 ----
          window.__bingsuResumeHook = () => {
            const S = window.SceneManager; if (!S) return;
            const now = performance.now();
            if (typeof S._currentTime === "number") { const gap = now - S._currentTime; S._currentTime = now; log("resume _currentTime gap=" + gap.toFixed(0) + "ms"); }
            if (typeof S._smoothDeltaTime === "number") { S._smoothDeltaTime = 1; S._elapsedTime = 0; log("resume smoothDelta reset"); }
          };
          log("shim " + ENGINE);
        })();
        """
    }

    /// 픽셀 아트를 흐리지 않게 (이 게임 설정 › 화면 › "픽셀 선명하게")
    static let pixelatedCSS = """
    (() => {
      const s = document.createElement("style");
      s.textContent = "canvas,video{image-rendering:pixelated}";
      (document.head || document.documentElement).appendChild(s);
    })();
    """
}
