import Foundation

extension BowlScripts {
    /// Node 흉내 공용 부품 (문서 시작 스크립트 안에 그대로 붙여 쓴다). 명세 docs/engines/IMPLEMENTATION-electron.md §5.1.
    ///
    /// `makeNodeKit(cfg)` 가 path·Buffer·fs·os·events·util·url·assert 와 CommonJS 로더(`makeLoader`)를 만든다.
    /// - 파일은 같은 출처(`cfg.origin`)로 보내는 **동기 XHR** 로 읽고 쓴다. 가상 경로 `/x/y` → `<출처>/x/y`. 스킴 핸들러가 권한을 정한다
    ///   (MV·MZ: `GreenTeaSchemeHandler` 의 `save/`, Electron: `RedBeanSchemeHandler` 의 `/userData/`).
    /// - 경로는 POSIX 식(`/`). `\` 는 `/` 로 바꿔 받는다. 상대 경로는 `cfg.cwd` 기준.
    /// - 없는 함수는 조용히 삼키지 않는다: Node 와 같은 오류(`ENOSYS`·`MODULE_NOT_FOUND`)를 던지고 `cfg.compat(무엇, 어느 파일)` 로 기록한다.
    ///
    /// cfg: `{ origin, cwd, log(msg), compat(what, file), os: { platform, type, homedir, tmpdir, EOL, arch } }`
    static let nodeKit = #"""
    const makeNodeKit = (cfg) => {
      const ORIGIN = cfg.origin;
      const CWD = cfg.cwd || "/";
      const log = cfg.log || (() => {});
      const compat = cfg.compat || (() => {});
      const noop = () => {};

      // ---- path (POSIX) ----
      const normalize = (p) => {
        let s = String(p).replace(/\\/g, "/").replace(/^file:\/\/+/i, "/");
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
        isAbsolute: (p) => String(p).replace(/\\/g, "/").startsWith("/"),
        join: (...a) => normalize(a.map(String).filter((x) => x !== "").join("/") || "."),
        resolve: (...a) => {
          let r = "";
          for (let i = a.length - 1; i >= 0; i--) {
            const s = String(a[i]).replace(/\\/g, "/"); if (!s) continue;
            r = r ? s + "/" + r : s; if (s.startsWith("/")) break;
          }
          if (!r.startsWith("/")) r = CWD + "/" + r;
          return trimEnd(normalize(r));
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
        toNamespacedPath: (p) => p,
      };
      path.posix = path; path.win32 = path;
      const urlOf = (p) => ORIGIN + path.resolve(String(p)).split("/").map(encodeURIComponent).join("/");

      // ---- Buffer (자주 쓰는 것만) ----
      class Buf extends Uint8Array {
        toString(enc, start, end) {
          const v = start !== undefined || end !== undefined ? this.subarray(start || 0, end === undefined ? this.length : end) : this;
          const e = String(enc || "utf8").toLowerCase();
          if (e === "base64" || e === "latin1" || e === "binary") {
            let s = ""; for (let i = 0; i < v.length; i += 0x8000) s += String.fromCharCode.apply(null, v.subarray(i, i + 0x8000));
            return e === "base64" ? btoa(s) : s;
          }
          if (e === "hex") return Array.from(v, (b) => b.toString(16).padStart(2, "0")).join("");
          return new TextDecoder("utf-8").decode(v);
        }
        toJSON() { return { type: "Buffer", data: Array.from(this) }; }
        equals(o) { if (!o || o.length !== this.length) return false; for (let i = 0; i < this.length; i++) if (this[i] !== o[i]) return false; return true; }
        copy(target, ts = 0, ss = 0, se = this.length) { const part = this.subarray(ss, se); target.set(part, ts); return part.length; }
        write(str, offset = 0) { const b = Buf.from(String(str)); this.set(b.subarray(0, this.length - offset), offset); return Math.min(b.length, this.length - offset); }
        static from(v, enc) {
          if (typeof v === "string") {
            const e = String(enc || "utf8").toLowerCase();
            if (e === "base64" || e === "latin1" || e === "binary") { const s = e === "base64" ? atob(v) : v; const b = new Buf(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 0xff; return b; }
            if (e === "hex") { const b = new Buf(v.length >> 1); for (let i = 0; i < b.length; i++) b[i] = parseInt(v.substr(i * 2, 2), 16); return b; }
            const u = new TextEncoder().encode(v); const b = new Buf(u.length); b.set(u); return b;
          }
          if (v instanceof ArrayBuffer) return new Buf(v.slice(0));
          if (ArrayBuffer.isView(v)) { const b = new Buf(v.byteLength); b.set(new Uint8Array(v.buffer, v.byteOffset, v.byteLength)); return b; }
          if (v && v.type === "Buffer" && Array.isArray(v.data)) return Buf.from(v.data);
          const b = new Buf(v && v.length || 0); if (v && v.length) b.set(v); return b;
        }
        static alloc(n, fill) { const b = new Buf(n); if (fill !== undefined) b.fill(typeof fill === "number" ? fill : Buf.from(String(fill))[0] || 0); return b; }
        static allocUnsafe(n) { return new Buf(n); }
        static isBuffer(v) { return v instanceof Buf; }
        static isEncoding(e) { return /^(utf-?8|base64|hex|latin1|binary|ascii)$/i.test(String(e)); }
        static byteLength(s) { return typeof s === "string" ? new TextEncoder().encode(s).length : (s && s.byteLength) || 0; }
        static concat(list) { const n = list.reduce((a, b) => a + b.length, 0); const out = new Buf(n); let o = 0; for (const b of list) { out.set(b, o); o += b.length; } return out; }
        static compare(a, b) { for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1; return a.length - b.length < 0 ? -1 : a.length > b.length ? 1 : 0; }
      }

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
      const MSG = { ENOENT: "no such file or directory", EACCES: "permission denied", ENOTDIR: "not a directory", EISDIR: "illegal operation on a directory",
                    EEXIST: "file already exists", EIO: "i/o error", ENOSYS: "function not implemented", ENOSPC: "no space left on device", ENOTEMPTY: "directory not empty" };
      const ERRNO = { ENOENT: -2, EACCES: -13, ENOTDIR: -20, EISDIR: -21, EEXIST: -17, EIO: -5, ENOSYS: -38, ENOSPC: -28, ENOTEMPTY: -39 };
      const fsErr = (code, syscall, p) => { const e = new Error(code + ": " + MSG[code] + ", " + syscall + " '" + p + "'"); e.code = code; e.errno = ERRNO[code]; e.syscall = syscall; e.path = String(p); return e; };
      const codeOf = (status, x) => {
        const hinted = x && x.getResponseHeader && x.getResponseHeader("X-Bingsu-Error");
        if (hinted && MSG[hinted]) return hinted;
        return status === 404 || status === 409 ? "ENOENT" : status === 403 ? "EACCES" : status === 405 ? "EEXIST" : status === 507 || status === 413 ? "ENOSPC" : "EIO";
      };
      const enc = (opt) => typeof opt === "string" ? opt : opt && opt.encoding;
      const isUtf8 = (e) => !!e && /^utf-?8$/i.test(String(e));
      const statOf = (p) => {
        const { status, x } = sx("HEAD", p);
        if (status !== 200) return null;
        const dir = x.getResponseHeader("X-Bingsu-Kind") === "dir";
        const ms = Number(x.getResponseHeader("X-Bingsu-Mtime")) || 0, d = new Date(ms);
        const size = Number(x.getResponseHeader("Content-Length")) || 0;
        return { isFile: () => !dir, isDirectory: () => dir, isSymbolicLink: () => false, isFIFO: () => false, isSocket: () => false,
                 isBlockDevice: () => false, isCharacterDevice: () => false, size, mode: dir ? 0o40755 : 0o100644, dev: 1, ino: 0, nlink: 1, uid: 0, gid: 0,
                 blksize: 4096, blocks: Math.ceil(size / 512), mtime: d, mtimeMs: ms, ctime: d, ctimeMs: ms, atime: d, atimeMs: ms, birthtime: d, birthtimeMs: ms };
      };
      const caller = () => {
        const s = String(new Error().stack || "").split("\n");
        for (const l of s) { const i = l.indexOf(ORIGIN); if (i >= 0) return l.slice(i + ORIGIN.length).replace(/\)$/, ""); }
        return "";
      };
      const missing = (name) => () => { compat("fs." + name, caller()); throw fsErr("ENOSYS", name, ""); };
      const writes = { count: 0 };
      const fs = {
        existsSync: (p) => { try { return !!statOf(p); } catch (e) { return false; } },
        statSync: (p, opt) => { const s = statOf(p); if (!s) { if (opt && opt.throwIfNoEntry === false) return undefined; throw fsErr("ENOENT", "stat", p); } return s; },
        accessSync: (p) => { if (!statOf(p)) throw fsErr("ENOENT", "access", p); },
        readFileSync: (p, opt) => {
          const e = enc(opt), text = isUtf8(e);
          const { status, x } = sx("GET", p, { binary: !text, text });
          if (status !== 200 && status !== 206) throw fsErr(codeOf(status, x), "open", p);
          if (x.getResponseHeader("X-Bingsu-Kind") === "dir") throw fsErr("EISDIR", "read", p);
          if (text) return x.responseText;
          const s = x.responseText, b = new Buf(s.length);
          for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 0xff;
          return e ? b.toString(e) : b;
        },
        writeFileSync: (p, data, opt) => {
          const e = enc(opt);
          if (opt && typeof opt === "object" && /^a/.test(String(opt.flag || ""))) return fs.appendFileSync(p, data, e);
          let body;
          if (typeof data === "string") body = e && !isUtf8(e) ? Buf.from(data, e) : data;
          else if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) body = data;
          else body = String(data);
          const { status, x } = sx("PUT", p, { body });
          writes.count++;
          if (status < 200 || status >= 300) { log("write failed " + status + " " + p); throw fsErr(codeOf(status, x), "open", p); }
        },
        appendFileSync: (p, data, opt) => {
          let old = ""; try { old = fs.readFileSync(p, "utf8"); } catch (e) {}
          fs.writeFileSync(p, old + (typeof data === "string" ? data : Buf.from(data).toString("utf8")), enc(opt));
        },
        copyFileSync: (a, b) => fs.writeFileSync(b, fs.readFileSync(a)),
        unlinkSync: (p) => { const { status, x } = sx("DELETE", p); if (status < 200 || status >= 300) throw fsErr(codeOf(status, x), "unlink", p); },
        rmdirSync: (p, opt) => {
          const { status, x } = sx("DELETE", p, { headers: opt && opt.recursive ? { "X-Bingsu-Recursive": "1" } : {} });
          if (status < 200 || status >= 300) throw fsErr(codeOf(status, x), "rmdir", p);
        },
        rmSync: (p, opt) => {
          const o = opt || {};
          const s = statOf(p);
          if (!s) { if (o.force) return; throw fsErr("ENOENT", "rm", p); }
          if (s.isDirectory() && !o.recursive) { const e = fsErr("EISDIR", "rm", p); e.code = "ERR_FS_EISDIR"; throw e; }
          const { status, x } = sx("DELETE", p, { headers: o.recursive ? { "X-Bingsu-Recursive": "1" } : {} });
          if ((status < 200 || status >= 300) && !(o.force && status === 404)) throw fsErr(codeOf(status, x), "rm", p);
        },
        mkdirSync: (p, opt) => {
          const recursive = opt === true || !!(opt && opt.recursive);
          const s = statOf(p);
          if (s) { if (recursive) return undefined; throw fsErr("EEXIST", "mkdir", p); }
          if (recursive) {
            // 없는 부모부터 차례로 만든다. 처음 만든 폴더 경로를 돌려준다 (Node 와 같게)
            const parts = path.resolve(String(p)).split("/").filter(Boolean);
            let cur = "", first;
            for (const seg of parts) {
              cur += "/" + seg;
              if (statOf(cur)) continue;
              const { status, x } = sx("MKCOL", cur);
              if (status < 200 || status >= 300) throw fsErr(codeOf(status, x), "mkdir", cur);
              if (first === undefined) first = cur;
            }
            return first;
          }
          const { status, x } = sx("MKCOL", p);
          if (status < 200 || status >= 300) throw fsErr(codeOf(status, x), "mkdir", p);
          return undefined;
        },
        readdirSync: (p, opt) => {
          const { status, x } = sx("GET", p, { text: true });
          if (status !== 200) throw fsErr(codeOf(status, x), "scandir", p);
          if (x.getResponseHeader("X-Bingsu-Kind") !== "dir") throw fsErr("ENOTDIR", "scandir", p);
          let names = []; try { names = JSON.parse(x.responseText); } catch (e) {}
          if (opt && opt.withFileTypes) return names.map((name) => { const s = statOf(path.join(String(p), name)); return { name, isFile: () => !!s && s.isFile(), isDirectory: () => !!s && s.isDirectory(), isSymbolicLink: () => false }; });
          return names;
        },
        renameSync: (a, b) => {
          const { status, x } = sx("MOVE", a, { headers: { Destination: urlOf(b) } });
          if (status < 200 || status >= 300) throw fsErr(codeOf(status, x), "rename", a);
        },
        realpathSync: (p) => { if (!statOf(p)) throw fsErr("ENOENT", "realpath", p); return path.resolve(String(p)); },
      };
      fs.lstatSync = fs.statSync; fs.realpathSync.native = fs.realpathSync;
      for (const n of ["openSync", "readSync", "writeSync", "closeSync", "fstatSync", "ftruncateSync", "truncateSync", "symlinkSync", "linkSync", "chmodSync", "utimesSync",
                       "watch", "watchFile", "unwatchFile", "createReadStream", "createWriteStream", "mkdtempSync", "opendirSync"]) {
        fs[n] = missing(n);
      }
      // 콜백판: 동기판을 setTimeout(0) 으로 감싼다
      const later = (fn) => function (...args) {
        const cb = typeof args[args.length - 1] === "function" ? args.pop() : null;
        setTimeout(() => { let r, err = null; try { r = fn(...args); } catch (e) { err = e; } if (cb) cb(err, r); }, 0);
      };
      const asyncNames = { readFile: "readFileSync", writeFile: "writeFileSync", appendFile: "appendFileSync", copyFile: "copyFileSync",
                           unlink: "unlinkSync", rmdir: "rmdirSync", rm: "rmSync", mkdir: "mkdirSync", readdir: "readdirSync",
                           rename: "renameSync", stat: "statSync", lstat: "lstatSync", access: "accessSync", realpath: "realpathSync" };
      fs.promises = {};
      for (const [a, s] of Object.entries(asyncNames)) {
        fs[a] = later(fs[s]);
        fs.promises[a] = (...args) => new Promise((ok, no) => setTimeout(() => { try { ok(fs[s](...args)); } catch (e) { no(e); } }, 0));
      }
      for (const n of ["open", "watch", "mkdtemp", "opendir"]) fs.promises[n] = (...a) => Promise.reject((() => { compat("fs.promises." + n, caller()); return fsErr("ENOSYS", n, ""); })());
      fs.exists = (p, cb) => setTimeout(() => { if (cb) cb(fs.existsSync(p)); }, 0);
      fs.constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1, COPYFILE_EXCL: 1 };
      Object.assign(fs, fs.constants);

      // ---- os ----
      const O = cfg.os || {};
      const os = { platform: () => O.platform || "linux", type: () => O.type || "Linux", arch: () => O.arch || "arm64", release: () => O.release || "0",
                   hostname: () => "bingsu", homedir: () => O.homedir || "/", tmpdir: () => O.tmpdir || "/tmp", EOL: O.EOL || "\n",
                   cpus: () => [], totalmem: () => 0, freemem: () => 0, uptime: () => Math.floor(performance.now() / 1000), loadavg: () => [0, 0, 0],
                   endianness: () => "LE", networkInterfaces: () => ({}), userInfo: () => ({ username: "player", homedir: O.homedir || "/", uid: -1, gid: -1, shell: null }) };

      // ---- events ----
      class EventEmitter {
        constructor() { Object.defineProperty(this, "_ev", { value: new Map(), writable: true, configurable: true }); this._max = 10; }
        _list(n) { if (!this._ev) Object.defineProperty(this, "_ev", { value: new Map(), writable: true, configurable: true }); let l = this._ev.get(n); if (!l) { l = []; this._ev.set(n, l); } return l; }
        on(n, f) { this._list(n).push({ f, once: false }); return this; }
        addListener(n, f) { return this.on(n, f); }
        prependListener(n, f) { this._list(n).unshift({ f, once: false }); return this; }
        once(n, f) { this._list(n).push({ f, once: true }); return this; }
        prependOnceListener(n, f) { this._list(n).unshift({ f, once: true }); return this; }
        off(n, f) { const l = this._list(n); const i = l.findIndex((e) => e.f === f || e.f.listener === f); if (i >= 0) l.splice(i, 1); return this; }
        removeListener(n, f) { return this.off(n, f); }
        removeAllListeners(n) { if (n === undefined) this._ev = new Map(); else if (this._ev) this._ev.delete(n); return this; }
        emit(n, ...a) {
          const l = this._ev && this._ev.get(n);
          if (!l || !l.length) { if (n === "error") throw (a[0] instanceof Error ? a[0] : new Error("Unhandled error. (" + a[0] + ")")); return false; }
          for (const e of l.slice()) { if (e.once) { const i = l.indexOf(e); if (i >= 0) l.splice(i, 1); } e.f.apply(this, a); }
          return true;
        }
        listeners(n) { return ((this._ev && this._ev.get(n)) || []).map((e) => e.f); }
        rawListeners(n) { return this.listeners(n); }
        listenerCount(n) { return ((this._ev && this._ev.get(n)) || []).length; }
        eventNames() { return this._ev ? [...this._ev.keys()].filter((k) => this._ev.get(k).length) : []; }
        setMaxListeners(n) { this._max = n; return this; }
        getMaxListeners() { return this._max; }
      }
      EventEmitter.EventEmitter = EventEmitter;
      EventEmitter.defaultMaxListeners = 10;
      EventEmitter.once = (em, n) => new Promise((ok) => em.once(n, (...a) => ok(a)));

      // ---- util ----
      const inspect = (v) => { if (typeof v === "string") return "'" + v + "'"; try { return JSON.stringify(v); } catch (e) { return String(v); } };
      const format = (f, ...a) => {
        if (typeof f !== "string") return [f, ...a].map((x) => typeof x === "string" ? x : inspect(x)).join(" ");
        let i = 0;
        let s = f.replace(/%[sdifjoO%]/g, (m) => {
          if (m === "%%") return "%";
          if (i >= a.length) return m;
          const v = a[i++];
          switch (m) { case "%s": return String(v); case "%d": case "%i": return String(m === "%i" ? parseInt(v) : Number(v)); case "%f": return String(parseFloat(v)); default: return inspect(v); }
        });
        for (; i < a.length; i++) s += " " + (typeof a[i] === "string" ? a[i] : inspect(a[i]));
        return s;
      };
      const customPromisify = Symbol.for("nodejs.util.promisify.custom");
      const util = {
        format, inspect, inherits: (c, p) => { Object.setPrototypeOf(c.prototype, p.prototype); Object.setPrototypeOf(c, p); c.super_ = p; },
        promisify: (fn) => fn[customPromisify] || ((...a) => new Promise((ok, no) => fn(...a, (err, v) => err ? no(err) : ok(v)))),
        callbackify: (fn) => (...a) => { const cb = a.pop(); fn(...a).then((v) => cb(null, v), (e) => cb(e)); },
        deprecate: (fn) => fn, debuglog: () => noop, isArray: Array.isArray, isDeepStrictEqual: (x, y) => { try { return JSON.stringify(x) === JSON.stringify(y); } catch (e) { return false; } },
        types: { isPromise: (v) => v instanceof Promise, isDate: (v) => v instanceof Date, isRegExp: (v) => v instanceof RegExp,
                 isTypedArray: (v) => ArrayBuffer.isView(v) && !(v instanceof DataView), isUint8Array: (v) => v instanceof Uint8Array, isArrayBuffer: (v) => v instanceof ArrayBuffer },
        TextEncoder, TextDecoder,
      };
      util.promisify.custom = customPromisify;
      inspect.custom = Symbol.for("nodejs.util.inspect.custom");

      // ---- url ----
      const url = {
        URL, URLSearchParams,
        fileURLToPath: (u) => { const s = typeof u === "string" ? u : String(u.href || u); return normalize(decodeURIComponent(s.replace(/^file:\/\/[^/]*/i, ""))); },
        pathToFileURL: (p) => new URL("file://" + path.resolve(String(p)).split("/").map(encodeURIComponent).join("/")),
        parse: (s) => { try { const u = new URL(s); return { href: u.href, protocol: u.protocol, host: u.host, hostname: u.hostname, port: u.port, pathname: u.pathname, search: u.search, query: u.search.slice(1), hash: u.hash }; } catch (e) { return { href: s, pathname: s }; } },
        format: (o) => typeof o === "string" ? o : o && o.href ? o.href : (o.protocol ? o.protocol + (o.slashes || /^file/.test(o.protocol) ? "//" : "") : "") + (o.host || o.hostname || "") + (o.pathname || "") + (o.search || ""),
      };

      // ---- assert (최소) ----
      class AssertionError extends Error { constructor(m) { super(m || "Assertion failed"); this.name = "AssertionError"; this.code = "ERR_ASSERTION"; } }
      const assert = (v, m) => { if (!v) throw new AssertionError(m); };
      const same = (x, y) => { try { return JSON.stringify(x) === JSON.stringify(y); } catch (e) { return x === y; } };
      Object.assign(assert, {
        ok: assert, AssertionError,
        equal: (a, b, m) => { if (a != b) throw new AssertionError(m || a + " == " + b); },
        notEqual: (a, b, m) => { if (a == b) throw new AssertionError(m || a + " != " + b); },
        strictEqual: (a, b, m) => { if (a !== b) throw new AssertionError(m || a + " === " + b); },
        notStrictEqual: (a, b, m) => { if (a === b) throw new AssertionError(m || a + " !== " + b); },
        deepEqual: (a, b, m) => { if (!same(a, b)) throw new AssertionError(m || "deepEqual"); },
        deepStrictEqual: (a, b, m) => { if (!same(a, b)) throw new AssertionError(m || "deepStrictEqual"); },
        throws: (fn, _e, m) => { try { fn(); } catch (e) { return; } throw new AssertionError(typeof _e === "string" ? _e : m || "Missing expected exception"); },
        fail: (m) => { throw new AssertionError(m || "Failed"); },
      });
      assert.strict = assert;

      // ---- CommonJS 로더 ----
      // realm: { builtins: { 이름: () => 모듈 }, process, global, cache(선택) }. 메인과 화면은 다른 프로세스라 캐시를 따로 둔다
      const CORE = new Set(["child_process", "net", "dgram", "worker_threads", "cluster", "http", "https", "http2", "tls", "zlib", "crypto", "stream",
                            "readline", "vm", "v8", "perf_hooks", "dns", "inspector", "tty", "module", "string_decoder", "querystring", "punycode",
                            "async_hooks", "diagnostics_channel", "repl", "trace_events", "wasi", "constants", "domain", "sys", "stream/promises", "fs/promises"]);
      const notFound = (request, from) => {
        const e = new Error("Cannot find module '" + request + "'" + (from ? "\nRequire stack:\n- " + from : ""));
        e.code = "MODULE_NOT_FOUND"; e.requireStack = from ? [from] : [];
        return e;
      };
      const isFile = (p) => { const s = statOf(p); return !!s && s.isFile(); };
      const readText = (p) => {
        const { status, x } = sx("GET", p, { text: true });
        if (status !== 200) throw fsErr(codeOf(status, x), "open", p);
        return x.responseText;
      };
      const makeLoader = (realm) => {
        const cache = realm.cache || Object.create(null);
        const tryFile = (base, inModules) => {
          for (const c of [base, base + ".js", base + ".json", base + ".cjs", base + ".node"]) if (isFile(c)) return c;
          // 폴더: node_modules 안에서만 package.json 의 main 을 본다 (명세 §5.1)
          if (inModules) {
            try {
              const pk = JSON.parse(readText(base + "/package.json"));
              if (pk && typeof pk.main === "string") {
                const m = path.join(base, pk.main);
                for (const c of [m, m + ".js", m + ".json", m + "/index.js"]) if (isFile(c)) return c;
              }
            } catch (e) {}
          }
          for (const c of [base + "/index.js", base + "/index.json"]) if (isFile(c)) return c;
          return null;
        };
        const resolve = (request, dir, from) => {
          const r = String(request).replace(/\\/g, "/");
          if (r.startsWith("./") || r.startsWith("../") || r.startsWith("/") || r === "." || r === "..") {
            const hit = tryFile(path.resolve(dir, r), path.resolve(dir, r).includes("/node_modules/"));
            if (hit) return hit;
            throw notFound(request, from);
          }
          // 맨이름: node_modules 를 위로 올라가며 찾는다
          let d = dir;
          while (true) {
            if (!d.endsWith("/node_modules")) { const hit = tryFile(path.join(d, "node_modules", r), true); if (hit) return hit; }
            if (d === "/" || d === "." || !d) break;
            d = path.dirname(d);
          }
          throw notFound(request, from);
        };
        const load = (file, parent) => {
          if (cache[file]) return cache[file].exports;
          const dir = path.dirname(file);
          const module = { id: file, filename: file, path: dir, exports: {}, loaded: false, parent: parent || null, children: [], paths: [] };
          if (/\.node$/i.test(file)) { compat("native addon " + file, parent ? parent.filename : ""); throw notFound(file, parent && parent.filename); }
          cache[file] = module;
          try {
            if (/\.json$/i.test(file)) { module.exports = JSON.parse(readText(file).replace(/^﻿/, "")); }
            else {
              let src = readText(file).replace(/^﻿/, "");
              if (src.startsWith("#!")) src = "//" + src;
              const req = makeRequire(dir, module);
              module.require = req;
              let fn;
              try {
                fn = (0, eval)("(function (exports, require, module, __filename, __dirname, process, global, Buffer, setImmediate, clearImmediate) {" + src
                               + "\n})\n//# sourceURL=" + ORIGIN + file.split("/").map(encodeURIComponent).join("/"));
              } catch (e) {
                if (e instanceof SyntaxError && /\b(import|export)\b/.test(String(e.message))) compat("ES module " + file, parent ? parent.filename : "");
                throw e;
              }
              fn.call(module.exports, module.exports, req, module, file, dir, realm.process, realm.global || window, Buf, realm.setImmediate, realm.clearImmediate);
            }
            module.loaded = true;
            if (parent) parent.children.push(module);
            return module.exports;
          } catch (e) { delete cache[file]; throw e; }
        };
        const makeRequire = (dir, mod) => {
          const from = mod ? mod.filename : dir + "/";
          const req = function require(name) {
            const n = String(name);
            const core = n.replace(/^node:/, "");
            if (Object.prototype.hasOwnProperty.call(realm.builtins, core)) return realm.builtins[core]();
            if (CORE.has(core) || n.startsWith("node:")) { compat("require('" + core + "')", from); throw notFound(n, from); }
            let file;
            try { file = resolve(n, dir, from); } catch (e) { compat("require('" + n + "')", from); throw e; }
            return load(file, mod);
          };
          req.resolve = (n) => { const core = String(n).replace(/^node:/, ""); return realm.builtins[core] ? core : resolve(String(n), dir, from); };
          req.cache = cache;
          req.main = realm.main;
          return req;
        };
        return { makeRequire, load, cache, resolve };
      };

      return { path, Buf, fs, os, EventEmitter, util, url, assert, urlOf, fsErr, statOf, sx, caller, makeLoader, writes };
    };
    """#
}
