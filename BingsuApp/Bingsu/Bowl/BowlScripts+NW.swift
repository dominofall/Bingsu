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
          const ENGINE = "\(engine.rawValue)";
          const ORIGIN = "\(GreenTeaSchemeHandler.origin)";
          const post = (body) => { try { window.webkit.messageHandlers.bowl.postMessage(body); } catch (e) {} };
          const native = (body) => { try { window.webkit.messageHandlers.mv.postMessage(body); } catch (e) {} };
          const log = (msg) => post({ event: "mv", msg: String(msg) });
          const noop = () => {};
          const quit = () => { log("quit"); native({ op: "quit" }); };

          // ---- path (POSIX, 게임 루트 = "/") ----
          const normalize = (p) => {
            let s = String(p).replace(/\\\\/g, "/").replace(/^file:\\/\\/+/i, "/");
            if (s.startsWith(ORIGIN)) s = s.slice(ORIGIN.length);
            const abs = s.startsWith("/"), out = [];
            for (const seg of s.split("/")) {
              if (!seg || seg === ".") continue;
              if (seg === "..") { if (out.length && out[out.length - 1] !== "..") out.pop(); else if (!abs) out.push(".."); continue; }
              out.push(seg);
            }
            let r = (abs ? "/" : "") + out.join("/");
            if (s.endsWith("/") && out.length) r += "/";
            return r || (abs ? "/" : ".");
          };
          const trimEnd = (s) => s.length > 1 && s.endsWith("/") ? s.slice(0, -1) : s;
          const path = {
            sep: "/", delimiter: ":", normalize,
            isAbsolute: (p) => String(p).replace(/\\\\/g, "/").startsWith("/"),
            join: (...a) => normalize(a.map(String).filter((x) => x !== "").join("/") || "."),
            resolve: (...a) => {
              let r = "";
              for (let i = a.length - 1; i >= 0; i--) {
                const s = String(a[i]).replace(/\\\\/g, "/"); if (!s) continue;
                r = r ? s + "/" + r : s; if (s.startsWith("/")) break;
              }
              return trimEnd(normalize("/" + r));
            },
            dirname: (p) => { const s = trimEnd(normalize(p)); const i = s.lastIndexOf("/"); return i < 0 ? "." : i === 0 ? "/" : s.slice(0, i); },
            basename: (p, ext) => { const s = trimEnd(normalize(p)); let b = s.slice(s.lastIndexOf("/") + 1); if (ext && b.endsWith(ext) && b !== ext) b = b.slice(0, -ext.length); return b; },
            extname: (p) => { const b = path.basename(p); const i = b.lastIndexOf("."); return i > 0 ? b.slice(i) : ""; },
            relative: (from, to) => {
              const f = path.resolve(from).split("/").filter(Boolean), t = path.resolve(to).split("/").filter(Boolean);
              let i = 0; while (i < f.length && i < t.length && f[i] === t[i]) i++;
              return f.slice(i).map(() => "..").concat(t.slice(i)).join("/");
            },
            parse: (p) => { const base = path.basename(p), ext = path.extname(p); return { root: path.isAbsolute(p) ? "/" : "", dir: path.dirname(p), base, ext, name: ext ? base.slice(0, -ext.length) : base }; },
            format: (o) => (o.dir ? o.dir + "/" : "") + (o.base || ((o.name || "") + (o.ext || ""))),
          };
          path.posix = path; path.win32 = path;
          const urlOf = (p) => ORIGIN + path.resolve(String(p)).split("/").map(encodeURIComponent).join("/");

          // ---- Buffer (from / toString 만 되는 최소 흉내) ----
          class Buf extends Uint8Array {
            toString(enc) {
              const e = String(enc || "utf8").toLowerCase();
              if (e === "base64" || e === "latin1" || e === "binary") {
                let s = ""; for (let i = 0; i < this.length; i += 0x8000) s += String.fromCharCode.apply(null, this.subarray(i, i + 0x8000));
                return e === "base64" ? btoa(s) : s;
              }
              if (e === "hex") return Array.from(this, (b) => b.toString(16).padStart(2, "0")).join("");
              return new TextDecoder("utf-8").decode(this);
            }
            static from(v, enc) {
              if (typeof v === "string") {
                const e = String(enc || "utf8").toLowerCase();
                if (e === "base64" || e === "latin1" || e === "binary") { const s = e === "base64" ? atob(v) : v; const b = new Buf(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 0xff; return b; }
                if (e === "hex") { const b = new Buf(v.length >> 1); for (let i = 0; i < b.length; i++) b[i] = parseInt(v.substr(i * 2, 2), 16); return b; }
                const u = new TextEncoder().encode(v); const b = new Buf(u.length); b.set(u); return b;
              }
              if (v instanceof ArrayBuffer) return new Buf(v.slice(0));
              if (ArrayBuffer.isView(v)) { const b = new Buf(v.byteLength); b.set(new Uint8Array(v.buffer, v.byteOffset, v.byteLength)); return b; }
              const b = new Buf(v && v.length || 0); if (v && v.length) b.set(v); return b;
            }
            static alloc(n) { return new Buf(n); }
            static isBuffer(v) { return v instanceof Buf; }
            static byteLength(s) { return typeof s === "string" ? new TextEncoder().encode(s).length : (s && s.byteLength) || 0; }
            static concat(list) { const n = list.reduce((a, b) => a + b.length, 0); const out = new Buf(n); let o = 0; for (const b of list) { out.set(b, o); o += b.length; } return out; }
          }
          if (typeof window.Buffer === "undefined") try { Object.defineProperty(window, "Buffer", { configurable: true, writable: true, value: Buf }); } catch (e) {}

          // ---- fs (동기 XHR → 스킴 핸들러) ----
          const sx = (method, p, opt) => {
            const o = opt || {}, x = new XMLHttpRequest();
            x.open(method, urlOf(p), false);
            for (const k in (o.headers || {})) x.setRequestHeader(k, o.headers[k]);
            if (o.binary) x.overrideMimeType("text/plain; charset=x-user-defined");
            else if (o.text) x.overrideMimeType("text/plain; charset=utf-8");
            try { x.send(o.body === undefined ? null : o.body); } catch (e) { return { status: 0, x }; }
            return { status: x.status, x };
          };
          const MSG = { ENOENT: "no such file or directory", EACCES: "permission denied", ENOTDIR: "not a directory", EISDIR: "illegal operation on a directory", EEXIST: "file already exists", EIO: "i/o error", ENOSYS: "function not implemented" };
          const ERRNO = { ENOENT: -2, EACCES: -13, ENOTDIR: -20, EISDIR: -21, EEXIST: -17, EIO: -5, ENOSYS: -38 };
          const fsErr = (code, syscall, p) => { const e = new Error(code + ": " + MSG[code] + ", " + syscall + " '" + p + "'"); e.code = code; e.errno = ERRNO[code]; e.syscall = syscall; e.path = String(p); return e; };
          const codeOf = (status) => status === 404 ? "ENOENT" : status === 403 ? "EACCES" : "EIO";
          const enc = (opt) => typeof opt === "string" ? opt : opt && opt.encoding;
          const isUtf8 = (e) => !!e && /^utf-?8$/i.test(String(e));
          const statOf = (p) => {
            const { status, x } = sx("HEAD", p);
            if (status !== 200) return null;
            const dir = x.getResponseHeader("X-Bingsu-Kind") === "dir";
            const ms = Number(x.getResponseHeader("X-Bingsu-Mtime")) || 0, d = new Date(ms);
            const size = Number(x.getResponseHeader("Content-Length")) || 0;
            return { isFile: () => !dir, isDirectory: () => dir, isSymbolicLink: () => false, size, mode: dir ? 0o40755 : 0o100644,
                     mtime: d, mtimeMs: ms, ctime: d, ctimeMs: ms, atime: d, atimeMs: ms, birthtime: d, birthtimeMs: ms };
          };
          const writes = { count: 0 };
          const fs = {
            existsSync: (p) => { try { return !!statOf(p); } catch (e) { return false; } },
            statSync: (p, opt) => { const s = statOf(p); if (!s) { if (opt && opt.throwIfNoEntry === false) return undefined; throw fsErr("ENOENT", "stat", p); } return s; },
            accessSync: (p) => { if (!statOf(p)) throw fsErr("ENOENT", "access", p); },
            readFileSync: (p, opt) => {
              const e = enc(opt), text = isUtf8(e);
              const { status, x } = sx("GET", p, { binary: !text, text });
              if (status !== 200 && status !== 206) throw fsErr(codeOf(status), "open", p);
              if (x.getResponseHeader("X-Bingsu-Kind") === "dir") throw fsErr("EISDIR", "read", p);
              if (text) return x.responseText;
              const s = x.responseText, b = new Buf(s.length);
              for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 0xff;
              return e ? b.toString(e) : b;
            },
            writeFileSync: (p, data, opt) => {
              const e = enc(opt);
              let body;
              if (typeof data === "string") body = e && !isUtf8(e) ? Buf.from(data, e) : data;
              else if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) body = data;
              else body = String(data);
              const { status } = sx("PUT", p, { body });
              writes.count++;
              if (status < 200 || status >= 300) { log("write failed " + status + " " + p); throw fsErr(codeOf(status), "open", p); }
            },
            appendFileSync: (p, data, opt) => {
              let old = ""; try { old = fs.readFileSync(p, "utf8"); } catch (e) {}
              fs.writeFileSync(p, old + (typeof data === "string" ? data : Buf.from(data).toString("utf8")), opt);
            },
            copyFileSync: (a, b) => fs.writeFileSync(b, fs.readFileSync(a)),
            unlinkSync: (p) => { const { status } = sx("DELETE", p); if (status < 200 || status >= 300) throw fsErr(codeOf(status), "unlink", p); },
            rmdirSync: (p) => { const { status } = sx("DELETE", p); if (status < 200 || status >= 300) throw fsErr(codeOf(status), "rmdir", p); },
            mkdirSync: (p, opt) => {
              const s = statOf(p);
              if (s) { if (opt && (opt.recursive || opt === true)) return undefined; throw fsErr("EEXIST", "mkdir", p); }
              const { status } = sx("MKCOL", p);
              if (status < 200 || status >= 300) throw fsErr(codeOf(status), "mkdir", p);
              return undefined;
            },
            readdirSync: (p, opt) => {
              const { status, x } = sx("GET", p, { text: true });
              if (status !== 200) throw fsErr(codeOf(status), "scandir", p);
              if (x.getResponseHeader("X-Bingsu-Kind") !== "dir") throw fsErr("ENOTDIR", "scandir", p);
              let names = []; try { names = JSON.parse(x.responseText); } catch (e) {}
              if (opt && opt.withFileTypes) return names.map((name) => { const s = statOf(path.join(String(p), name)); return { name, isFile: () => !!s && s.isFile(), isDirectory: () => !!s && s.isDirectory(), isSymbolicLink: () => false }; });
              return names;
            },
            renameSync: (a, b) => {
              const { status } = sx("MOVE", a, { headers: { Destination: urlOf(b) } });
              if (status < 200 || status >= 300) throw fsErr(codeOf(status), "rename", a);
            },
          };
          fs.lstatSync = fs.statSync; fs.rmSync = fs.unlinkSync;
          for (const n of ["openSync", "readSync", "writeSync", "closeSync", "watch", "watchFile", "createReadStream", "createWriteStream"]) {
            fs[n] = () => { throw fsErr("ENOSYS", n, ""); };
          }
          // 콜백판: 동기판을 setTimeout(0) 으로 감싼다
          const later = (fn) => function (...args) {
            const cb = typeof args[args.length - 1] === "function" ? args.pop() : null;
            setTimeout(() => { let r, err = null; try { r = fn(...args); } catch (e) { err = e; } if (cb) cb(err, r); }, 0);
          };
          const asyncNames = { readFile: "readFileSync", writeFile: "writeFileSync", appendFile: "appendFileSync", copyFile: "copyFileSync",
                               unlink: "unlinkSync", rmdir: "rmdirSync", rm: "rmSync", mkdir: "mkdirSync", readdir: "readdirSync",
                               rename: "renameSync", stat: "statSync", lstat: "lstatSync", access: "accessSync" };
          fs.promises = {};
          for (const [a, s] of Object.entries(asyncNames)) {
            fs[a] = later(fs[s]);
            fs.promises[a] = (...args) => new Promise((ok, no) => setTimeout(() => { try { ok(fs[s](...args)); } catch (e) { no(e); } }, 0));
          }
          fs.exists = (p, cb) => setTimeout(() => { if (cb) cb(fs.existsSync(p)); }, 0);
          fs.constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 };

          // ---- os ----
          const os = { platform: () => "linux", type: () => "Linux", arch: () => "arm64", release: () => "0", hostname: () => "bingsu",
                       homedir: () => "/", tmpdir: () => "/tmp", EOL: "\\n", cpus: () => [], totalmem: () => 0, freemem: () => 0,
                       networkInterfaces: () => ({}), userInfo: () => ({ username: "player", homedir: "/" }) };

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
