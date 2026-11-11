import Foundation

extension BowlScripts {
    /// 팥빙수(새 모양 Electron) 흉내 (문서 시작). 명세 docs/engines/IMPLEMENTATION-electron.md §5.2·§5.3·§6.
    ///
    /// 메인 프로세스(`package.json` 의 main)와 화면을 **같은 웹뷰** 에서 돌린다.
    /// 1. Node 흉내(`nodeKit`) 위에 `require('electron')` 을 만든다. 메인과 화면이 같은 객체를 받는다.
    /// 2. 메인 스크립트를 CommonJS 로더로 실행한다(모듈 캐시는 메인·화면 따로). 오류가 나도 화면은 띄운다.
    /// 3. `app.whenReady()` 를 풀고 `ready` 를 낸다. 게임이 `BrowserWindow` 를 만들고 `ipcMain.handle` 을 건다.
    /// 4. 화면 쪽 준비는 그 창의 webPreferences 를 따른다. 창은 마이크로태스크에서 생길 수 있어서, 가져올 때 글자로 읽어 둔 값
    ///    (`ElectronInfo.nodeIntegration`·`preload`)으로 먼저 준비하고, 창이 생기면 다르게 말한 것만 더한다.
    /// 5. `ipcRenderer.invoke` 는 메인 준비가 끝날 때까지 기다렸다 넘긴다.
    ///
    /// 창 크기: 내용 크기(`setContentSize` → 생성자 width·height → 1280×720)를 배율(`setZoomFactor`)로 나눈 값을 네이티브에 알린다
    /// (`redbean` 메시지 `{ op: "window", w, h }`). 네이티브가 웹뷰를 그 크기로 만들고 화면에 맞게 줄인다.
    /// 목록에 없는 API 는 `undefined` 대신 기록 남기는 대역(Proxy)을 준다. 게임이 멈추지 않는 것이 먼저다.
    static func electronShim(_ info: ElectronInfo) -> String {
        let cfg: [String: Any] = [
            "main": "/app/" + info.main,
            "entry": "/app/" + info.entry,
            "nodeIntegration": info.nodeIntegration,
            "preload": info.preload.map { "/app/" + $0 } ?? NSNull(),
            "addons": info.nativeAddons,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: cfg)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return #"""
        (() => {
          // PC 창처럼 웹뷰 크기 = 레이아웃 크기. 문서 끝에 붙는 공통 viewport 보다 먼저 넣어야 페이지의 첫 스크립트가
          // 기본 폭(980)이 아닌 창 크기를 innerWidth 로 읽는다 (시험 게임에서 확인)
          try {
            const vp = document.createElement("meta"); vp.name = "viewport";
            vp.content = "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover";
            (document.head || document.documentElement).appendChild(vp);
          } catch (e) {}
        \#(nodeKit)
          const CFG = \#(json);
          const ORIGIN = "\#(RedBeanSchemeHandler.origin)";
          const post = (body) => { try { window.webkit.messageHandlers.bowl.postMessage(body); } catch (e) {} };
          const native = (body) => { try { window.webkit.messageHandlers.redbean.postMessage(body); } catch (e) {} };
          const log = (msg) => post({ event: "redbean", msg: String(msg) });
          const noted = new Set();
          const compat = (what, file) => { const k = what + "|" + (file || ""); if (noted.has(k)) return; noted.add(k); post({ event: "compat", msg: String(what).slice(0, 200), src: String(file || "").slice(0, 160) }); };
          const noop = () => {};
          const kit = makeNodeKit({ origin: ORIGIN, cwd: "/app", log, compat,
                                    os: { platform: "win32", type: "Windows_NT", arch: "x64", release: "10.0.22631", homedir: "/home", tmpdir: "/tmp", EOL: "\r\n" } });
          const { path, Buf, fs, os, EventEmitter, util, url, assert, caller } = kit;
          const clone = (v) => v === undefined ? undefined : structuredClone(v);
          const later = (fn) => setTimeout(fn, 0);

          // 기록 남기는 대역: 목록에 없는 것을 꺼내면 한 번 기록하고, 부르면 아무것도 안 한다
          const stub = (name) => new Proxy(function () {}, {
            get: (t, k) => {
              if (typeof k === "symbol" || k in Function.prototype) return Reflect.get(t, k);
              if (k === "then") return undefined;
              return stub(name + "." + k);
            },
            apply: () => { compat(name + "()", caller()); return undefined; },
            construct: () => { compat("new " + name, caller()); return stub(name + "#"); },
          });
          const known = (obj, name) => new Proxy(obj, {
            get: (t, k, r) => {
              if (typeof k === "symbol" || k in t) return Reflect.get(t, k, r);
              if (k === "then" || k === "toJSON" || k === "__esModule" || k === "default") return undefined;
              compat(name + "." + k, caller());
              return stub(name + "." + k);
            },
          });

          // ---- package.json ----
          let PKG = {};
          try { PKG = JSON.parse(fs.readFileSync("/app/package.json", "utf8")); } catch (e) {}
          let appName = PKG.productName || PKG.name || "app";

          // ---- process (메인 browser · 화면 renderer) ----
          const makeProcess = (type) => {
            const p = new EventEmitter();
            Object.assign(p, {
              type, platform: "win32", arch: "x64", pid: type === "browser" ? 1 : 2, ppid: 0, title: appName, version: "v20.18.1",
              versions: { node: "20.18.1", chrome: "128.0.6613.186", electron: "32.3.3", v8: "12.8.374.38-electron.0", uv: "1.48.0", modules: "128" },
              env: { APPDATA: "/appData", LOCALAPPDATA: "/appData", HOME: "/home", USERPROFILE: "/home", TEMP: "/tmp", TMP: "/tmp", OS: "Windows_NT" },
              argv: ["/app/app.exe"], execArgv: [], execPath: "/app/app.exe", resourcesPath: "/app", contextIsolated: false, sandboxed: false,
              windowsStore: false, exitCode: undefined, release: { name: "node" }, config: {}, features: {},
              cwd: () => "/app", chdir: noop, umask: () => 0o22, uptime: () => performance.now() / 1000,
              exit: () => quitApp(), abort: () => quitApp(), kill: noop,
              nextTick: (fn, ...a) => queueMicrotask(() => fn(...a)),
              hrtime: Object.assign((prev) => { const t = performance.now(), s = Math.floor(t / 1000), n = Math.floor((t % 1000) * 1e6); return prev ? [s - prev[0], n - prev[1]] : [s, n]; },
                                    { bigint: () => BigInt(Math.floor(performance.now() * 1e6)) }),
              memoryUsage: () => ({ rss: 0, heapTotal: 0, heapUsed: 0, external: 0, arrayBuffers: 0 }),
              getProcessMemoryInfo: () => Promise.resolve({ private: 0, shared: 0, residentSet: 0 }),
              getSystemMemoryInfo: () => ({ total: 0, free: 0 }), getCPUUsage: () => ({ percentCPUUsage: 0, idleWakeupsPerSecond: 0 }),
              stdout: { write: (s) => { console.log(String(s)); return true; }, isTTY: false }, stderr: { write: (s) => { console.warn(String(s)); return true; }, isTTY: false },
              emitWarning: (w) => console.warn(String(w)),
            });
            return p;
          };
          const mainProc = makeProcess("browser"), rendererProc = makeProcess("renderer");
          const setImm = (fn, ...a) => setTimeout(fn, 0, ...a), clearImm = (id) => clearTimeout(id);

          // ---- ipc ----
          const handlers = new Map();
          const waiters = new Map();
          let mainSettled = false; const settledWaiters = [];
          const ipcMain = new EventEmitter();
          const ipcRenderer = new EventEmitter();
          const wake = (ch) => { const ws = waiters.get(ch); if (ws) { waiters.delete(ch); for (const w of ws) w(); } };
          Object.assign(ipcMain, {
            handle(ch, fn) { if (handlers.has(ch)) throw new Error("Attempted to register a second handler for '" + ch + "'"); handlers.set(ch, { fn, once: false }); wake(ch); },
            handleOnce(ch, fn) { handlers.set(ch, { fn, once: true }); wake(ch); },
            removeHandler(ch) { handlers.delete(ch); },
          });
          let webContents = null;   // 창이 생기면 채운다
          const mainEvent = () => {
            const ev = { sender: webContents, senderFrame: { url: location.href, routingId: 1 }, frameId: 1, processId: 2, returnValue: undefined,
                         defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ports: [] };
            ev.reply = (c, ...a) => { if (webContents) webContents.send(c, ...a); };
            return ev;
          };
          const waitHandler = (ch) => new Promise((ok) => {
            const go = () => {
              if (handlers.has(ch)) return ok(handlers.get(ch));
              const ws = waiters.get(ch) || []; ws.push(() => ok(handlers.get(ch))); waiters.set(ch, ws);
              // 메인 준비가 끝난 뒤에도 2초 동안 안 걸리면 진짜와 같이 거절
              setTimeout(() => ok(handlers.get(ch) || null), 2000);
            };
            if (mainSettled) go(); else settledWaiters.push(go);
          });
          const rendererEvent = () => ({ sender: ipcRenderer, senderId: 0, ports: [] });
          Object.assign(ipcRenderer, {
            async invoke(ch, ...args) {
              const a = clone(args);
              let h = handlers.get(ch);
              if (!h) h = await waitHandler(ch);
              if (!h) throw new Error("Error invoking remote method '" + ch + "': Error: No handler registered for '" + ch + "'");
              if (h.once) handlers.delete(ch);
              try { return clone(await h.fn(mainEvent(), ...a)); }
              catch (e) { throw new Error("Error invoking remote method '" + ch + "': " + ((e && e.name) || "Error") + ": " + ((e && e.message) || e)); }
            },
            send(ch, ...args) { const a = clone(args); later(() => ipcMain.emit(ch, mainEvent(), ...a)); },
            sendSync(ch, ...args) { const ev = mainEvent(); ipcMain.emit(ch, ev, ...clone(args)); return clone(ev.returnValue); },
            sendTo(id, ch, ...args) { const a = clone(args); later(() => ipcRenderer.emit(ch, rendererEvent(), ...a)); },
            sendToHost(ch) { compat("ipcRenderer.sendToHost", caller()); },
            postMessage(ch, msg) { const m = clone(msg); later(() => ipcMain.emit(ch, mainEvent(), m)); },
          });

          // ---- 창 크기 → 네이티브 ----
          const SCREEN = { w: 1920, h: 1080 };
          let zoom = 1, lastSent = "";
          const reportSize = (win) => {
            if (!win) return;
            const w = Math.round(win._cw / zoom), h = Math.round(win._ch / zoom);
            const k = w + "x" + h;
            if (k === lastSent || !(w >= 100 && h >= 100 && w <= 8000 && h <= 8000)) return;
            lastSent = k;
            log("window " + win._cw + "x" + win._ch + " zoom=" + zoom + " → layout " + k);
            native({ op: "window", w, h });
            settle(w, h);
          };
          // 웹뷰 크기가 바뀌는 중간에 resize 이벤트가 먼저 오고(그때 innerWidth 는 중간 값) 최종 크기로는 다시 오지 않을 때가 있다
          // (시험 게임: 마지막 resize 735×490, 실제 960×640). resize 때만 크기를 읽는 게임을 위해, 크기가 자리 잡으면 한 번 더 알린다
          let seen = innerWidth + "x" + innerHeight, settleId = 0;
          window.addEventListener("resize", () => { seen = innerWidth + "x" + innerHeight; }, true);
          const settle = (w, h) => {
            const id = ++settleId, t0 = performance.now();
            const tick = () => {
              if (id !== settleId) return;
              if (innerWidth === w && innerHeight === h) {
                if (seen !== w + "x" + h) { seen = w + "x" + h; window.dispatchEvent(new Event("resize")); log("resize re-sent " + w + "x" + h); }
                return;
              }
              if (performance.now() - t0 < 3000) requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
          };
          const setZoom = (k) => { const n = Number(k); if (!(n > 0.1 && n < 10)) return; if (n !== zoom) { zoom = n; reportSize(primary); } };

          // ---- webContents ----
          const makeWebContents = (win) => {
            const wc = new EventEmitter();
            let openHandler = null;
            const session = known({
              clearCache: () => Promise.resolve(), clearStorageData: () => Promise.resolve(), setPermissionRequestHandler: noop, setPermissionCheckHandler: noop,
              setUserAgent: noop, getUserAgent: () => navigator.userAgent, setProxy: () => Promise.resolve(), setSpellCheckerEnabled: noop,
              webRequest: { onBeforeRequest: noop, onBeforeSendHeaders: noop, onHeadersReceived: noop, onCompleted: noop, onErrorOccurred: noop },
              on: noop, once: noop, protocol: stub("session.protocol"),
            }, "session");
            Object.assign(wc, {
              id: 1, session,
              send(ch, ...args) { const a = clone(args); later(() => ipcRenderer.emit(ch, rendererEvent(), ...a)); },
              postMessage(ch, msg) { const m = clone(msg); later(() => ipcRenderer.emit(ch, rendererEvent(), m)); },
              setZoomFactor: setZoom, getZoomFactor: () => zoom,
              setZoomLevel: (l) => setZoom(Math.pow(1.2, Number(l) || 0)), getZoomLevel: () => Math.log(zoom) / Math.log(1.2),
              setVisualZoomLevelLimits: () => Promise.resolve(), setIgnoreMenuShortcuts: noop,
              openDevTools: noop, closeDevTools: noop, toggleDevTools: noop, isDevToolsOpened: () => false, isDevToolsFocused: () => false,
              setWindowOpenHandler: (fn) => { openHandler = fn; }, setAudioMuted: (m) => { compat("webContents.setAudioMuted", caller()); }, isAudioMuted: () => false,
              executeJavaScript: (code) => Promise.resolve().then(() => (0, eval)(String(code))),
              insertCSS: (css) => { const s = document.createElement("style"); s.textContent = String(css); (document.head || document.documentElement).appendChild(s); return Promise.resolve("css" + Math.random()); },
              removeInsertedCSS: () => Promise.resolve(),
              getURL: () => location.href, getTitle: () => document.title, isLoading: () => document.readyState !== "complete", isLoadingMainFrame: () => false,
              isCrashed: () => false, isDestroyed: () => false, isFocused: () => true, focus: noop, reload: () => location.reload(), reloadIgnoringCache: () => location.reload(),
              getOwnerBrowserWindow: () => win, setBackgroundThrottling: noop, setFrameRate: noop, getFrameRate: () => 60, invalidate: noop,
              setUserAgent: noop, getUserAgent: () => navigator.userAgent, canGoBack: () => false, goBack: noop, stop: noop, mainFrame: { url: location.href, routingId: 1 },
              print: () => compat("webContents.print", caller()), printToPDF: () => Promise.reject(new Error("printToPDF is not supported")),
              capturePage: () => { compat("webContents.capturePage", caller()); return Promise.resolve(nativeImage.createEmpty()); },
              loadFile: (f) => win.loadFile(f), loadURL: (u) => win.loadURL(u),
            });
            return known(wc, "webContents");
          };

          // ---- BrowserWindow ----
          let primary = null;
          const domState = { dom: false, load: false };
          class BrowserWindow extends EventEmitter {
            constructor(opts) {
              if (primary) { compat("second BrowserWindow", caller()); return primary; }
              super();
              const o = opts || {};
              primary = this;
              this.id = 1; this._opts = o;
              this._cw = Number(o.width) > 0 ? Math.round(o.width) : 1280;
              this._ch = Number(o.height) > 0 ? Math.round(o.height) : 720;
              this._windowed = [this._cw, this._ch];
              this._fs = false; this._resizable = o.resizable !== false; this._visible = o.show !== false; this._destroyed = false;
              this._title = o.title || document.title || appName;
              webContents = makeWebContents(this);
              this.webContents = webContents;
              if (o.fullscreen) this._enterFs(false);
              const wp = o.webPreferences || {};
              if (o.webPreferences && wp.zoomFactor) setZoom(wp.zoomFactor);
              applyRenderer({ nodeIntegration: !!wp.nodeIntegration, preload: wp.preload ? path.resolve(String(wp.preload)) : null }, "BrowserWindow");
              log("BrowserWindow " + this._cw + "x" + this._ch + " node=" + !!wp.nodeIntegration + " isolation=" + (wp.contextIsolation !== false) + " preload=" + (wp.preload ? path.basename(String(wp.preload)) : "-"));
              reportSize(this);
              // 문서가 이미 떠 있으면 이벤트를 다음 틱에 낸다
              if (domState.dom) later(() => { this.emit("ready-to-show"); webContents.emit("dom-ready"); });
              if (domState.load) later(() => { webContents.emit("did-finish-load"); webContents.emit("did-stop-loading"); });
              return known(this, "BrowserWindow");
            }
            static getAllWindows() { return primary && !primary._destroyed ? [primary] : []; }
            static getFocusedWindow() { return primary && !primary._destroyed ? primary : null; }
            static fromWebContents() { return primary; }
            static fromId(id) { return id === 1 ? primary : null; }
            static fromBrowserView() { return primary; }
            _setContent(w, h) {
              w = Math.round(Number(w)); h = Math.round(Number(h));
              if (!(w > 0 && h > 0)) return;
              const changed = w !== this._cw || h !== this._ch;
              this._cw = w; this._ch = h;
              if (!this._fs) this._windowed = [w, h];
              if (changed) { reportSize(this); later(() => this.emit("resize")); }
            }
            _enterFs(emit) {
              if (this._fs) return;
              this._windowed = [this._cw, this._ch]; this._fs = true;
              this._cw = SCREEN.w; this._ch = SCREEN.h; reportSize(this);
              if (emit) later(() => { this.emit("enter-full-screen"); this.emit("resize"); });
            }
            loadFile(f) {
              const target = path.resolve("/app", String(f).replace(/\\/g, "/").split(/[?#]/)[0]);
              if (decodeURIComponent(location.pathname) !== target) compat("loadFile other page " + target, caller());
              return Promise.resolve();
            }
            loadURL(u) {
              const s = String(u);
              const here = location.href.split(/[?#]/)[0];
              if (s.split(/[?#]/)[0] !== here) compat("loadURL " + s.slice(0, 120), caller());
              return Promise.resolve();
            }
            show() { this._visible = true; later(() => this.emit("show")); }
            showInactive() { this.show(); }
            hide() { this._visible = false; }
            isVisible() { return this._visible; }
            focus() {} blur() {} isFocused() { return true; } focusOnWebView() {}
            center() {} moveTop() {} setPosition() {} getPosition() { return [0, 0]; }
            close() {
              if (this._destroyed) return;
              const ev = { defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
              this.emit("close", ev);
              if (ev.defaultPrevented) return;
              this.destroy();
            }
            destroy() {
              if (this._destroyed) return;
              this._destroyed = true;
              this.emit("closed");
              // 마지막 창이 닫힘: 게임이 window-all-closed 를 들으면 거기서 app.quit(), 안 들으면 진짜와 같이 끝낸다
              if (!app.emit("window-all-closed")) quitApp();
            }
            isDestroyed() { return this._destroyed; }
            getContentSize() { return [this._cw, this._ch]; }
            setContentSize(w, h) { this._setContent(w, h); }
            getSize() { return [this._cw, this._ch]; }
            setSize(w, h) { this._setContent(w, h); }
            getBounds() { return { x: 0, y: 0, width: this._cw, height: this._ch }; }
            getContentBounds() { return this.getBounds(); }
            getNormalBounds() { return this.getBounds(); }
            setBounds(b) { if (b && (b.width || b.height)) this._setContent(b.width || this._cw, b.height || this._ch); }
            setContentBounds(b) { this.setBounds(b); }
            setMinimumSize() {} setMaximumSize() {} getMinimumSize() { return [0, 0]; } getMaximumSize() { return [0, 0]; }
            setAspectRatio() {}
            setFullScreen(on) {
              if (on) { this._enterFs(true); return; }
              if (!this._fs) return;
              this._fs = false;
              [this._cw, this._ch] = this._windowed; reportSize(this);
              later(() => { this.emit("leave-full-screen"); this.emit("resize"); });
            }
            isFullScreen() { return this._fs; }
            setSimpleFullScreen(on) { this.setFullScreen(on); } isSimpleFullScreen() { return this._fs; }
            setKiosk(on) { this.setFullScreen(on); } isKiosk() { return this._fs; }
            isFullScreenable() { return true; } setFullScreenable() {}
            setResizable(v) { this._resizable = !!v; } isResizable() { return this._resizable; }
            setMovable() {} isMovable() { return true; } setMinimizable() {} isMinimizable() { return true; }
            setMaximizable() {} isMaximizable() { return true; } setClosable() {} isClosable() { return true; }
            maximize() {} unmaximize() {} isMaximized() { return false; } minimize() {} restore() {} isMinimized() { return false; } isNormal() { return true; }
            setAlwaysOnTop() {} isAlwaysOnTop() { return false; }
            setMenu() {} removeMenu() {} setMenuBarVisibility() {} isMenuBarVisible() { return false; } setAutoHideMenuBar() {} isMenuBarAutoHide() { return true; }
            setTitle(t) { this._title = String(t); } getTitle() { return this._title; }
            setIcon() {} setProgressBar() {} flashFrame() {} setSkipTaskbar() {} setBackgroundColor() {} getBackgroundColor() { return "#000000"; }
            setOpacity() {} getOpacity() { return 1; } setHasShadow() {} setIgnoreMouseEvents() {} setContentProtection() {} setFocusable() {}
            setThumbarButtons() { return true; } setOverlayIcon() {} setAppDetails() {} setVibrancy() {} setBackgroundMaterial() {}
            getNativeWindowHandle() { return Buf.alloc(8); } getParentWindow() { return null; } getChildWindows() { return []; }
          }

          // ---- app ----
          const app = new EventEmitter();
          let readyFired = false, resolveReady;
          const readyPromise = new Promise((ok) => { resolveReady = ok; });
          let quitting = false;
          const quitApp = () => { if (quitting) return; quitting = true; log("quit"); native({ op: "quit" }); };
          const PATHS = { userData: "/userData", appData: "/appData", home: "/home", temp: "/tmp", documents: "/home/Documents", desktop: "/home/Desktop",
                          downloads: "/home/Downloads", music: "/home/Music", pictures: "/home/Pictures", videos: "/home/Videos", recent: "/appData/Recent",
                          exe: "/app/app.exe", module: "/app/app.exe", logs: "/userData/logs", sessionData: "/userData", crashDumps: "/userData/Crashpad", cache: "/appData" };
          Object.assign(app, {
            whenReady: () => readyPromise, isReady: () => readyFired,
            getPath(name) { const p = PATHS[name]; if (!p) throw new Error("Failed to get '" + name + "' path"); return p; },
            setPath(name, p) { compat("app.setPath " + name, caller()); },
            getAppPath: () => "/app", getName: () => appName, setName: (n) => { appName = String(n); },
            getVersion: () => PKG.version || "0.0.0", getLocale: () => "ko", getSystemLocale: () => "ko-KR", getLocaleCountryCode: () => "KR",
            getPreferredSystemLanguages: () => ["ko-KR"], isPackaged: true, isInApplicationsFolder: () => false,
            quit() {
              const ev = { defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
              app.emit("before-quit", ev); if (ev.defaultPrevented) return;
              app.emit("will-quit", ev); if (ev.defaultPrevented) return;
              app.emit("quit", ev, 0); quitApp();
            },
            exit: () => quitApp(), relaunch: () => { compat("app.relaunch", caller()); }, focus: noop, hide: noop, show: noop,
            requestSingleInstanceLock: () => true, hasSingleInstanceLock: () => true, releaseSingleInstanceLock: noop,
            disableHardwareAcceleration: noop, disableDomainBlockingFor3DAPIs: noop, setAppUserModelId: noop, setAboutPanelOptions: noop, showAboutPanel: noop,
            setLoginItemSettings: noop, getLoginItemSettings: () => ({ openAtLogin: false, openAsHidden: false }), setAsDefaultProtocolClient: () => false,
            isDefaultProtocolClient: () => false, removeAsDefaultProtocolClient: () => false, addRecentDocument: noop, clearRecentDocuments: noop,
            getAppMetrics: () => [], getGPUFeatureStatus: () => ({}), getGPUInfo: () => Promise.resolve({}), setBadgeCount: () => false, getBadgeCount: () => 0,
            setUserTasks: () => true, setJumpList: noop, isAccessibilitySupportEnabled: () => false, setAccessibilitySupportEnabled: noop,
            commandLine: { appendSwitch: noop, appendArgument: noop, hasSwitch: () => false, getSwitchValue: () => "", removeSwitch: noop },
            applicationMenu: null, userAgentFallback: navigator.userAgent, allowRendererProcessReuse: true,
          });
          Object.defineProperty(app, "name", { get: () => appName, set: (n) => { appName = String(n); } });

          // ---- 그 밖 ----
          const screenDisplay = () => ({ id: 1, label: "Bingsu", bounds: { x: 0, y: 0, width: SCREEN.w, height: SCREEN.h }, workArea: { x: 0, y: 0, width: SCREEN.w, height: SCREEN.h },
                                         size: { width: SCREEN.w, height: SCREEN.h }, workAreaSize: { width: SCREEN.w, height: SCREEN.h }, scaleFactor: 1, rotation: 0,
                                         internal: false, touchSupport: "unknown", monochrome: false, colorDepth: 24, colorSpace: "", depthPerComponent: 8, displayFrequency: 60, accelerometerSupport: "unknown" });
          const screen = Object.assign(new EventEmitter(), {
            getPrimaryDisplay: screenDisplay, getAllDisplays: () => [screenDisplay()], getDisplayMatching: screenDisplay, getDisplayNearestPoint: screenDisplay,
            getCursorScreenPoint: () => ({ x: 0, y: 0 }), dipToScreenPoint: (p) => p, screenToDipPoint: (p) => p,
          });
          const askBox = (opts) => {
            const o = opts || {};
            const text = [o.title, o.message, o.detail].filter(Boolean).join("\n\n");
            const buttons = Array.isArray(o.buttons) ? o.buttons : [];
            if (buttons.length <= 1) { window.alert(text); return 0; }
            const ok = window.confirm(text);
            const cancel = typeof o.cancelId === "number" ? o.cancelId : buttons.length - 1;
            const def = typeof o.defaultId === "number" ? o.defaultId : 0;
            return ok ? (def === cancel ? 0 : def) : cancel;
          };
          const winArg = (a) => a[0] instanceof BrowserWindow || (a[0] && a[0] === primary) ? a.slice(1) : a;
          const dialog = {
            showMessageBox: (...a) => { const o = winArg(a)[0] || {}; return Promise.resolve({ response: askBox(o), checkboxChecked: !!o.checkboxChecked }); },
            showMessageBoxSync: (...a) => askBox(winArg(a)[0]),
            showErrorBox: (title, content) => window.alert([title, content].filter(Boolean).join("\n\n")),
            showOpenDialog: () => { compat("dialog.showOpenDialog", caller()); return Promise.resolve({ canceled: true, filePaths: [] }); },
            showOpenDialogSync: () => { compat("dialog.showOpenDialogSync", caller()); return undefined; },
            showSaveDialog: () => { compat("dialog.showSaveDialog", caller()); return Promise.resolve({ canceled: true, filePath: "" }); },
            showSaveDialogSync: () => { compat("dialog.showSaveDialogSync", caller()); return undefined; },
            showCertificateTrustDialog: () => Promise.resolve(),
          };
          const shell = {
            openExternal: (u) => { native({ op: "open", url: String(u) }); return Promise.resolve(); },
            openPath: (p) => { compat("shell.openPath", caller()); return Promise.resolve(""); },
            showItemInFolder: () => compat("shell.showItemInFolder", caller()), beep: noop,
            trashItem: () => Promise.reject(new Error("trashItem is not supported")), writeShortcutLink: () => false, readShortcutLink: () => ({}),
          };
          const clipboard = {
            writeText: (t) => { try { navigator.clipboard.writeText(String(t)).catch(noop); } catch (e) {} },
            readText: () => "", clear: noop, writeHTML: noop, readHTML: () => "", writeImage: noop, readImage: () => nativeImage.createEmpty(),
            availableFormats: () => [], has: () => false, write: noop, read: () => "",
          };
          const makeImage = (dataURL) => ({ isEmpty: () => !dataURL, toDataURL: () => dataURL || "", getSize: () => ({ width: 0, height: 0 }), resize() { return this; },
                                            crop() { return this; }, toPNG: () => Buf.alloc(0), toJPEG: () => Buf.alloc(0), toBitmap: () => Buf.alloc(0),
                                            getAspectRatio: () => 1, setTemplateImage: noop, isTemplateImage: () => false, addRepresentation: noop });
          const nativeImage = {
            createEmpty: () => makeImage(""), createFromPath: () => makeImage(""), createFromDataURL: (u) => makeImage(String(u)),
            createFromBuffer: () => makeImage(""), createFromBitmap: () => makeImage(""), createFromNamedImage: () => makeImage(""),
          };
          const webFrame = {
            setZoomFactor: setZoom, getZoomFactor: () => zoom, setZoomLevel: (l) => setZoom(Math.pow(1.2, Number(l) || 0)), getZoomLevel: () => Math.log(zoom) / Math.log(1.2),
            setVisualZoomLevelLimits: noop, setLayoutZoomLevelLimits: noop, clearCache: noop, getResourceUsage: () => ({}),
            insertCSS: (css) => { const s = document.createElement("style"); s.textContent = String(css); (document.head || document.documentElement).appendChild(s); return "css"; },
            executeJavaScript: (code) => Promise.resolve().then(() => (0, eval)(String(code))),
            setSpellCheckProvider: noop, routingId: 1,
          };
          const contextBridge = {
            exposeInMainWorld: (k, api) => { try { Object.defineProperty(window, k, { configurable: true, writable: false, value: api }); } catch (e) { window[k] = api; } },
            exposeInIsolatedWorld: (id, k, api) => { compat("contextBridge.exposeInIsolatedWorld", caller()); window[k] = api; },
          };
          class Menu { constructor() { this.items = []; } static buildFromTemplate(t) { const m = new Menu(); m.items = (t || []).map((i) => new MenuItem(i)); return m; }
                       static setApplicationMenu() {} static getApplicationMenu() { return null; } static sendActionToFirstResponder() {}
                       append(i) { this.items.push(i); } insert(n, i) { this.items.splice(n, 0, i); } popup() {} closePopup() {} getMenuItemById() { return null; } }
          class MenuItem { constructor(o) { Object.assign(this, o || {}); } }
          class Tray extends EventEmitter { setToolTip() {} setContextMenu() {} setImage() {} setTitle() {} destroy() {} isDestroyed() { return false; } displayBalloon() {} }
          class Notification extends EventEmitter { constructor(o) { super(); this.opts = o; } static isSupported() { return false; } show() {} close() {} }
          const globalShortcut = { register: () => true, registerAll: noop, unregister: noop, unregisterAll: noop, isRegistered: () => false };
          const powerSaveBlocker = { start: () => 1, stop: noop, isStarted: () => false };
          const nativeTheme = Object.assign(new EventEmitter(), { shouldUseDarkColors: false, shouldUseHighContrastColors: false, shouldUseInvertedColorScheme: false, themeSource: "system" });
          const autoUpdater = Object.assign(new EventEmitter(), { setFeedURL: noop, getFeedURL: () => "", checkForUpdates: noop, quitAndInstall: noop });
          const powerMonitor = Object.assign(new EventEmitter(), { getSystemIdleState: () => "active", getSystemIdleTime: () => 0, isOnBatteryPower: () => false, onBatteryPower: false });
          const crashReporter = { start: noop, getLastCrashReport: () => null, getUploadedReports: () => [], addExtraParameter: noop, removeExtraParameter: noop, getParameters: () => ({}) };
          const sessionMod = { get defaultSession() { return webContents ? webContents.session : stub("session.defaultSession"); }, fromPartition: () => (webContents ? webContents.session : stub("session")) };

          const electron = known({
            app, BrowserWindow, ipcMain, ipcRenderer, screen, dialog, shell, clipboard, nativeImage, webFrame, contextBridge, Menu, MenuItem, Tray,
            Notification, globalShortcut, powerSaveBlocker, nativeTheme, autoUpdater, powerMonitor, crashReporter, session: sessionMod,
            get webContents() { return { getAllWebContents: () => (webContents ? [webContents] : []), getFocusedWebContents: () => webContents, fromId: () => webContents }; },
          }, "electron");

          // ---- 내장 모듈 ----
          const builtins = (proc) => ({
            electron: () => electron, fs: () => fs, "original-fs": () => fs, "fs/promises": () => fs.promises, path: () => path, os: () => os,
            events: () => EventEmitter, util: () => util, url: () => url, assert: () => assert, buffer: () => ({ Buffer: Buf, kMaxLength: 2 ** 31 - 1 }),
            timers: () => ({ setTimeout, clearTimeout, setInterval, clearInterval, setImmediate: setImm, clearImmediate: clearImm }),
            process: () => proc,
          });
          const mainRealm = { builtins: builtins(mainProc), process: mainProc, global: window, setImmediate: setImm, clearImmediate: clearImm };
          const rendererRealm = { builtins: builtins(rendererProc), process: rendererProc, global: window, setImmediate: setImm, clearImmediate: clearImm };
          const mainLoader = kit.makeLoader(mainRealm), rendererLoader = kit.makeLoader(rendererRealm);

          // ---- 화면 쪽 준비 (nodeIntegration·preload) ----
          const applied = { node: false, preload: null };
          const def = (k, v) => { try { Object.defineProperty(window, k, { configurable: true, writable: true, value: v }); } catch (e) {} };
          function applyRenderer(prefs, why) {
            if (prefs.nodeIntegration && !applied.node) {
              applied.node = true;
              const dir = path.dirname(CFG.entry);
              const mod = { id: ".", filename: CFG.entry, path: dir, exports: {}, loaded: false, parent: null, children: [], paths: [] };
              const req = rendererLoader.makeRequire(dir, mod);
              def("require", req); def("module", mod); def("exports", mod.exports); def("__dirname", dir); def("__filename", CFG.entry);
              def("global", window); def("process", rendererProc); def("Buffer", Buf); def("setImmediate", setImm); def("clearImmediate", clearImm);
              if (why !== "hint") log("renderer nodeIntegration on (" + why + ")");
            } else if (!prefs.nodeIntegration && applied.node && why !== "hint") {
              compat("nodeIntegration hint differs (false at runtime)", "");
            }
            if (prefs.preload && applied.preload !== prefs.preload) {
              if (applied.preload) compat("second preload " + prefs.preload, "");
              applied.preload = prefs.preload;
              try { rendererLoader.load(prefs.preload, null); log("preload ran " + prefs.preload + " (" + why + ")"); }
              catch (e) { post({ event: "error", msg: "preload: " + String((e && e.stack) || e).slice(0, 800) }); }
            }
          }

          window.close = () => { if (primary) primary.close(); else quitApp(); };

          // ---- 메인 실행 → ready ----
          if (CFG.addons && CFG.addons.length) log("native addons in game: " + CFG.addons.join(", "));
          try {
            const mainMod = { filename: CFG.main };
            mainRealm.main = mainMod; mainProc.mainModule = mainMod;
            mainLoader.load(CFG.main, null);
            mainRealm.main = mainLoader.cache[CFG.main] || mainMod; mainProc.mainModule = mainRealm.main;
            log("main ran " + CFG.main + " handlers=" + handlers.size);
          } catch (e) {
            post({ event: "error", msg: "main: " + String((e && e.stack) || e).slice(0, 1200) });
          }
          readyFired = true;
          try { app.emit("will-finish-launching"); app.emit("ready", {}, {}); } catch (e) { post({ event: "error", msg: "app ready: " + String((e && e.stack) || e).slice(0, 800) }); }
          resolveReady();
          // 창이 아직 없으면 가져올 때 읽어 둔 값으로 화면 쪽을 먼저 준비한다 (첫 <script> 보다 먼저)
          applyRenderer({ nodeIntegration: CFG.nodeIntegration, preload: CFG.preload }, "hint");
          setTimeout(() => {
            mainSettled = true;
            for (const go of settledWaiters.splice(0)) go();
            if (!primary) log("no BrowserWindow yet");
          }, 0);

          document.addEventListener("DOMContentLoaded", () => {
            domState.dom = true;
            if (primary) { primary.emit("ready-to-show"); webContents.emit("dom-ready"); }
          });
          window.addEventListener("load", () => {
            domState.load = true;
            if (primary) { webContents.emit("did-finish-load"); webContents.emit("did-stop-loading"); }
            log("page loaded " + innerWidth + "x" + innerHeight + " handlers=" + handlers.size);
          });
        })();
        """#
    }
    /// 팥빙수 게임의 `<audio>` 보정 (문서 시작, Ogg 폴리필·atDocumentStart 다음). 명세 §7.
    ///
    /// iOS WebKit 의 `<audio>` 는 .ogg 를 못 튼다(0단계: `NotSupportedError`, code 4). `src`·`new Audio(src)` 가 .ogg 면
    /// 파일을 받아 지금 있는 Ogg 폴리필(OfflineAudioContext.decodeAudioData)로 풀고 WAV Blob 주소로 바꿔 끼운다.
    /// 주소별로 캐시하고(합계 상한) 풀지 못하면 원래 주소를 넣어 게임 쪽 오류 처리(다른 확장자 시도 등)가 그대로 돌게 한다.
    /// `src` 를 읽으면 게임이 넣은 주소를 돌려준다.
    /// 그리고 빙수 일시정지(`__bingsu.pause/resume`)·게임별 음량(`setVolume`)이 Web Audio 만 다루므로 `<audio>` 에도 걸어 준다.
    static func mediaShim(volume: Double) -> String {
        #"""
        (() => {
          const M = window.HTMLMediaElement; if (!M) return;
          const post = (msg) => { try { window.webkit.messageHandlers.bowl.postMessage({ event: "audio", msg: String(msg) }); } catch (e) {} };
          const srcDesc = Object.getOwnPropertyDescriptor(M.prototype, "src");
          const volDesc = Object.getOwnPropertyDescriptor(M.prototype, "volume");
          const play = M.prototype.play, pauseEl = M.prototype.pause;
          if (!srcDesc || !srcDesc.set) return;
          const OGG = /\.(ogg|oga)$/i;
          const isOgg = (u) => { try { return OGG.test(new URL(u, document.baseURI).pathname); } catch (e) { return false; } };
          const abs = (u) => { try { return new URL(u, document.baseURI).href; } catch (e) { return String(u); } };

          // ---- ogg → wav ----
          const cache = new Map();   // 주소 → { p: Promise<blob 주소>, bytes }
          let total = 0; const LIMIT = 96 * 1024 * 1024;
          let off = null;
          const wav = (ab) => {
            const ch = ab.numberOfChannels, n = ab.length, rate = ab.sampleRate;
            const out = new DataView(new ArrayBuffer(44 + n * ch * 2));
            const tag = (o, t) => { for (let i = 0; i < 4; i++) out.setUint8(o + i, t.charCodeAt(i)); };
            tag(0, "RIFF"); out.setUint32(4, 36 + n * ch * 2, true); tag(8, "WAVE"); tag(12, "fmt ");
            out.setUint32(16, 16, true); out.setUint16(20, 1, true); out.setUint16(22, ch, true); out.setUint32(24, rate, true);
            out.setUint32(28, rate * ch * 2, true); out.setUint16(32, ch * 2, true); out.setUint16(34, 16, true); tag(36, "data"); out.setUint32(40, n * ch * 2, true);
            const data = []; for (let c = 0; c < ch; c++) data.push(ab.getChannelData(c));
            let o = 44;
            for (let i = 0; i < n; i++) for (let c = 0; c < ch; c++) { const v = Math.max(-1, Math.min(1, data[c][i])); out.setInt16(o, v < 0 ? v * 0x8000 : v * 0x7fff, true); o += 2; }
            return out.buffer;
          };
          const evict = () => {
            for (const [k, v] of cache) {
              if (total <= LIMIT) break;
              if (!v.url) continue;
              cache.delete(k); total -= v.bytes; try { URL.revokeObjectURL(v.url); } catch (e) {}
            }
          };
          const convert = (url) => {
            const hit = cache.get(url);
            if (hit) { cache.delete(url); cache.set(url, hit); return hit.p; }
            const entry = { url: null, bytes: 0, p: null };
            entry.p = (async () => {
              const t0 = performance.now();
              const r = await fetch(url);
              if (!r.ok) throw new Error("HTTP " + r.status);
              const buf = await r.arrayBuffer();
              if (!off) off = new (window.OfflineAudioContext || window.webkitOfflineAudioContext)(1, 1, 44100);
              const ab = await off.decodeAudioData(buf);
              const out = wav(ab);
              entry.url = URL.createObjectURL(new Blob([out], { type: "audio/wav" }));
              entry.bytes = out.byteLength; total += out.byteLength; evict();
              post("ogg media " + url.split("/").pop().slice(0, 60) + " " + (out.byteLength / 1024).toFixed(0) + "KB in " + (performance.now() - t0).toFixed(0) + "ms");
              return entry.url;
            })();
            entry.p.catch((e) => { cache.delete(url); post("ogg media failed " + url.split("/").pop().slice(0, 60) + " " + ((e && e.message) || e)); });
            cache.set(url, entry);
            return entry.p;
          };
          const setSrc = (el, v) => {
            const s = String(v);
            if (s && isOgg(s)) {
              const a = abs(s);
              el.__bsSrc = a;
              el.__bsPending = convert(a).then((blob) => { if (el.__bsSrc === a) srcDesc.set.call(el, blob); },
                                                () => { if (el.__bsSrc === a) srcDesc.set.call(el, a); })
                                         .finally(() => { if (el.__bsSrc === a) el.__bsPending = null; });
              return;
            }
            el.__bsSrc = null; el.__bsPending = null;
            srcDesc.set.call(el, s);
          };
          Object.defineProperty(M.prototype, "src", {
            configurable: true, enumerable: srcDesc.enumerable,
            get() { return this.__bsSrc != null ? this.__bsSrc : srcDesc.get.call(this); },
            set(v) { setSrc(this, v); },
          });
          const setAttr = Element.prototype.setAttribute;
          Element.prototype.setAttribute = function (k, v) {
            if (this instanceof M && String(k).toLowerCase() === "src" && isOgg(String(v))) { setSrc(this, v); return; }
            return setAttr.call(this, k, v);
          };
          const A = window.Audio;
          if (A) {
            const Audio = function Audio(src) {
              const el = new A();
              if (src !== undefined) el.src = src;
              return el;
            };
            Audio.prototype = A.prototype;
            try { Object.defineProperty(window, "Audio", { configurable: true, writable: true, value: Audio }); } catch (e) { window.Audio = Audio; }
          }

          // ---- 빙수 일시정지·음량 ----
          const live = new Set(), held = new Set();
          let PAUSED = false, VOLUME = \#(min(1, max(0, volume)));
          const applyVol = (el) => { if (volDesc && volDesc.set) try { volDesc.set.call(el, (el.__bsVol == null ? 1 : el.__bsVol) * VOLUME); } catch (e) {} };
          const track = (el) => {
            if (el.__bsTracked) return; el.__bsTracked = true;
            el.addEventListener("ended", () => live.delete(el));
            el.addEventListener("pause", () => { if (!PAUSED) live.delete(el); });
            el.addEventListener("error", () => live.delete(el));
          };
          // 파일마다 첫 재생 결과를 한 번만 남긴다 (소리가 나는지 기록으로 확인)
          const noted = new Set();
          const note = (el, ok, e) => {
            const name = String(el.__bsSrc || srcDesc.get.call(el) || "").split("/").pop().slice(0, 60);
            const k = name + ok; if (noted.has(k) || noted.size > 80) return; noted.add(k);
            post("media play " + (ok ? "ok " : "failed ") + decodeURIComponent(name) + (ok ? "" : " " + ((e && e.name) || e)));
          };
          const watch = (el, p) => (p && p.then) ? p.then((v) => { note(el, true); return v; }, (e) => { note(el, false, e); throw e; }) : p;
          M.prototype.play = function () {
            track(this); applyVol(this); live.add(this);
            if (PAUSED) { held.add(this); return Promise.resolve(); }
            if (this.__bsPending) { const p = this.__bsPending; return p.then(() => watch(this, play.call(this))); }
            return watch(this, play.call(this));
          };
          if (volDesc && volDesc.set) {
            Object.defineProperty(M.prototype, "volume", {
              configurable: true, enumerable: volDesc.enumerable,
              get() { return this.__bsVol == null ? volDesc.get.call(this) : this.__bsVol; },
              set(v) { const n = Number(v); if (!(n >= 0 && n <= 1)) return volDesc.set.call(this, v); this.__bsVol = n; applyVol(this); },
            });
          }
          // iOS 는 <audio> 의 volume 을 무시할 수 있다 (손으로 확인해 기록)
          try { const t = new A(); volDesc.set.call(t, 0.5); post("media volume settable=" + (Math.abs(volDesc.get.call(t) - 0.5) < 0.01)); } catch (e) {}
          const B = window.__bingsu;
          if (B) {
            const p0 = B.pause, r0 = B.resume, v0 = B.setVolume;
            B.pause = function () {
              if (!PAUSED) { PAUSED = true; for (const el of live) if (!el.paused) { held.add(el); try { pauseEl.call(el); } catch (e) {} } }
              return p0 && p0.apply(this, arguments);
            };
            B.resume = function () {
              const r = r0 && r0.apply(this, arguments);
              if (PAUSED) { PAUSED = false; for (const el of held) { try { const p = play.call(el); if (p && p.catch) p.catch(() => {}); } catch (e) {} } held.clear(); }
              return r;
            };
            B.setVolume = function (v) {
              const n = Number(v); VOLUME = Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 1;
              for (const el of live) applyVol(el);
              return v0 && v0.apply(this, arguments);
            };
          }
        })();
        """#
    }
}
