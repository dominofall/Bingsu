import Foundation

extension BowlScripts {
    /// 빨대(터치 조작): 손가락을 PC 마우스로 바꾸는 문서 시작 스크립트. 명세 docs/engines/IMPLEMENTATION-touch.md §2~§4.
    ///
    /// 엔진과 상관없는 공용 스크립트지만 지금은 새 모양 Electron 게임(`dish.isRedBean`)에만 넣는다.
    /// - 한 손가락 = 왼쪽 단추. 닿는 순간 `mousedown`, 움직이면 `mousemove`, 떼면 `mouseup`(+ 짧았으면 `click`).
    ///   0.45초 가만히 있으면 가리키기만(떼도 click 없음), 한계(화면 10pt)를 넘게 움직이면 끌기.
    /// - WebKit 이 탭 뒤에 몰아서 만드는 진짜 마우스 이벤트는 `window` capture 에서 막는다(게임이 클릭을 두 번 받지 않게).
    /// - `mousedown`·`click` 은 페이지의 `pointerdown`·`touchstart`·`touchend` 처리기가 다 돈 뒤(MessageChannel 작업)에 보내
    ///   페이지의 `preventDefault` 를 PC·모바일 브라우저 규칙대로 따른다.
    /// - 입력 칸(키보드·선택기가 떠야 하는 것)은 변환하지 않고 WebKit 에 맡긴다.
    /// - 누르고 있는 중에 다른 손가락이 닿으면 앞 손가락의 누름을 그 자리에서 끝내고(`mouseup`, 탭이었으면 `click` 까지)
    ///   새 손가락이 마우스가 된다 (§2.1, 두 엄지로 번갈아 빨리 눌러도 탭이 사라지지 않게). 진짜 포인터·터치 이벤트는 손가락마다 그대로 간다.
    /// - 오른쪽 클릭·휠·확대는 하지 않는다 (§13). 진짜 마우스·트랙패드의 것은 그대로 간다.
    /// - CSS `:hover` 는 `[data-bingsu-hover]` 로 바꿔 넣고 가리키는 요소와 조상에 그 표시를 붙인다. `title` 은 말풍선으로.
    /// - 진짜 마우스·트랙패드는 변환하지 않는다(가리키기 표시와 말풍선만 같이 쓴다).
    ///
    /// 네이티브 → 스크립트: `__bingsuStraw.setScale(배율)`, `cancel()`.
    /// 스크립트 → 네이티브: `straw` 메시지 `{ op: "hold" }`(가리키기 진동), 로그는 `bowl` 의 `straw` 사건.
    static func strawShim(debug: Bool) -> String {
        #"""
        (() => {
          if (window.__bingsuStraw) return;
          const DEBUG = \#(debug ? "true" : "false");
          const post = (name, body) => { try { window.webkit.messageHandlers[name].postMessage(body); } catch (e) {} };
          const log = (msg) => post("bowl", { event: "straw", msg: String(msg) });
          const HOLD_MS = 450, SLOP_PT = 10, DBL_MS = 400, TIP_MS = 600, TIP_MAX = 300;
          const ATTR = "data-bingsu-hover";
          const now = () => performance.now();
          // 화면 pt ÷ CSS px (게임을 줄여 그린 배율). 네이티브가 알려 준다
          let scale = 0.5;
          const slop = () => SLOP_PT / Math.max(0.05, scale);

          // §2.5 "터치 기기"로 보이지 않게: ontouch* 속성을 감춘다. 이벤트 자체는 그대로 흐른다
          for (const name of ["ontouchstart", "ontouchmove", "ontouchend", "ontouchcancel"]) {
            for (const o of [window, Window.prototype, Document.prototype, HTMLElement.prototype, Element.prototype,
                             typeof SVGElement === "function" ? SVGElement.prototype : null]) {
              try { if (o && Object.prototype.hasOwnProperty.call(o, name)) delete o[name]; } catch (e) {}
            }
          }

          // 페이지 처리기가 다 돈 뒤(같은 입력 작업이 끝난 다음 작업)에 할 일
          const defer = (() => {
            const ch = new MessageChannel(), q = [];
            ch.port1.onmessage = () => { const f = q.shift(); if (f) try { f(); } catch (e) { log("error " + e); } };
            return (f) => { q.push(f); ch.port2.postMessage(0); };
          })();

          // §2.4 그대로 두는 요소: 키보드·선택기·조절 막대는 진짜 사용자 동작이어야 뜬다
          const KEEP_INPUT = new Set(["checkbox", "radio", "button", "submit", "reset", "image"]);
          const isPass = (el) => {
            if (!el || el.nodeType !== 1) return false;
            if (el.isContentEditable) return true;
            const p = el.closest ? el.closest("input, textarea, select, video[controls], audio[controls]") : null;
            if (!p) return false;
            if (p.tagName === "INPUT") return !KEEP_INPUT.has(String(p.type || "text").toLowerCase());
            return true;
          };

          // 손가락 아래 요소 (열린 shadow root 안까지)
          const hit = (x, y) => {
            let el = document.elementFromPoint(x, y);
            for (let i = 0; el && el.shadowRoot && i < 8; i++) {
              const inner = el.shadowRoot.elementFromPoint(x, y);
              if (!inner || inner === el) break;
              el = inner;
            }
            return el;
          };
          const up = (n) => n.parentElement || (n.parentNode && n.parentNode.host) || null;

          // PC 처럼 채운 마우스 이벤트. mouseenter·mouseleave 는 버블링하지 않고 취소할 수 없다
          let last = { x: 0, y: 0 };
          const fire = (type, el, x, y, o) => {
            if (!el) return true;
            o = o || {};
            const bubbles = type !== "mouseenter" && type !== "mouseleave";
            const ev = new MouseEvent(type, {
              bubbles, cancelable: bubbles, composed: true, view: window, detail: o.detail || 0,
              clientX: x, clientY: y, screenX: x + (window.screenX || 0), screenY: y + (window.screenY || 0),
              movementX: type === "mousemove" ? x - last.x : 0, movementY: type === "mousemove" ? y - last.y : 0,
              button: o.button || 0, buttons: o.buttons || 0, relatedTarget: o.related || null,
              ctrlKey: false, shiftKey: false, altKey: false, metaKey: false,
            });
            const ok = el.dispatchEvent(ev);
            if (type === "mousemove") last = { x, y };
            return ok;
          };

          // §2.2 가리키기: 지금 가리키는 요소 하나와 그 조상 줄
          let hover = null, hoverChain = [];
          let hoverRules = 0;
          const chainOf = (el) => { const a = []; for (let n = el; n && a.length < 200; n = up(n)) a.push(n); return a; };
          const setHover = (el, x, y, events) => {
            if (el === hover) return false;
            const old = hover, oldChain = hoverChain.filter((n) => n.isConnected);
            const chain = el ? chainOf(el) : [];
            const inNew = new Set(chain), inOld = new Set(oldChain);
            hover = el; hoverChain = chain;
            if (events) {
              const from = old && old.isConnected ? old : null;
              if (from) fire("mouseout", from, x, y, { related: el });
              for (const n of oldChain) if (!inNew.has(n)) fire("mouseleave", n, x, y, { related: el });
              if (el) {
                fire("mouseover", el, x, y, { related: from });
                for (let i = chain.length - 1; i >= 0; i--) if (!inOld.has(chain[i])) fire("mouseenter", chain[i], x, y, { related: from });
              }
            }
            for (const n of oldChain) if (!inNew.has(n) && n.removeAttribute) n.removeAttribute(ATTR);
            if (hoverRules > 0) for (const n of chain) if (!inOld.has(n) && n.setAttribute) n.setAttribute(ATTR, "");
            return true;
          };
          const markHoverNow = () => { if (hoverRules > 0) for (const n of hoverChain) if (n.isConnected && n.setAttribute) n.setAttribute(ATTR, ""); };

          // 입력 칸에 포커스가 있을 때 다른 곳을 누르면 키보드를 내린다
          const blurField = (target) => {
            const a = document.activeElement;
            if (a && a !== document.body && isPass(a) && !(a === target || (a.contains && a.contains(target)))) { try { a.blur(); } catch (e) {} }
          };
          const common = (a, b) => {
            if (!a || !a.isConnected) return b;
            if (!b) return a;
            const s = new Set(chainOf(a));
            for (let n = b; n; n = up(n)) if (s.has(n)) return n;
            return b;
          };

          // §2.1 한 손가락
          // mousedown·click 은 touchstart·touchend 가 window 버블 단계에 닿을 때 바로 보낸다(이 스크립트가 먼저 등록해 페이지의 window
          // 버블 처리기보다 앞). 그 안이어야 click 처리기에서 복사·파일 고르기 같은 "사용자 동작"이 된다 (0단계 2번).
          // 페이지가 전파를 멈춰 거기까지 오지 않으면 다음 작업(defer)에서 보낸다
          let lastType = "";          // 마지막 진짜 포인터 종류
          let converted = false;      // 마지막 손가락 터치를 바꿨다 → WebKit 의 마우스 이벤트를 막는다
          let t = null;               // 지금 손가락
          let lastClick = { t: -1e9, x: 0, y: 0, n: 0 };

          const start = (cur) => {
            if (t !== cur || cur.cancelled || cur.started) return;
            cur.started = true;
            cur.noAny = !!(cur.ts && cur.ts.defaultPrevented);
            cur.noMouse = cur.noAny || cur.pd.defaultPrevented;
            if (cur.noAny) return;
            const x = cur.x0, y = cur.y0;
            cur.detail = now() - lastClick.t < DBL_MS && Math.hypot(x - lastClick.x, y - lastClick.y) <= slop() ? lastClick.n + 1 : 1;
            const el = hit(x, y) || cur.target;
            // 커서가 이 자리로 "온" 것. PC 에선 누르기 전에 생기는 mousemove 라서 pointerdown 을 막아도 보낸다
            // (마지막 커서 자리를 mousemove 로 기억하는 게임이 옛 자리를 붙들지 않게)
            setHover(el, x, y, true);
            fire("mousemove", el, x, y);
            cur.down = el;
            if (!cur.noMouse) fire("mousedown", el, x, y, { button: 0, buttons: 1, detail: cur.detail });
            cur.sent = true;
            if (cur.x !== x || cur.y !== y) move(cur);
            if (DEBUG) log("down " + Math.round(x) + "," + Math.round(y) + " " + tag(el) + (cur.noMouse ? " noMouse" : "") + " detail=" + cur.detail);
          };
          const move = (cur) => {
            const el = hit(cur.x, cur.y) || hover;
            setHover(el, cur.x, cur.y, true);
            if (!cur.noMouse) fire("mousemove", el, cur.x, cur.y, { buttons: 1 });
            if (cur.hold) showTipFor(el, cur.x, cur.y);
          };
          const finish = (cur) => {
            if (cur.finished) return;
            cur.finished = true;
            if (t === cur) t = null;
            if (cur.cancelled || cur.noAny || !cur.sent) return;
            const x = cur.x, y = cur.y;
            const el = hit(x, y) || hover;
            setHover(el, x, y, true);
            // touchend 를 막은 게임: 이미 보낸 mousedown 만 닫고 click 은 없다 (구현 기록)
            const blocked = !!(cur.te && cur.te.defaultPrevented);
            if (!cur.noMouse) fire("mouseup", el, x, y, { button: 0, buttons: 0, detail: cur.detail });
            if (!cur.drag && !cur.hold && !blocked) {
              const target = common(cur.down, el);
              fire("click", target, x, y, { button: 0, buttons: 0, detail: cur.detail });
              if (cur.detail === 2) fire("dblclick", target, x, y, { button: 0, buttons: 0, detail: 2 });
              lastClick = { t: now(), x, y, n: cur.detail };
            } else lastClick = { t: -1e9, x: 0, y: 0, n: 0 };
            if (DEBUG) log("up " + (cur.drag ? "drag" : cur.hold ? "hold" : blocked ? "blocked" : "click") + " " + tag(el));
            hideTip();
            setHover(null, x, y, true);
          };
          const cancel = (cur, why) => {
            if (!cur || cur.cancelled) return;
            cur.cancelled = true;
            clearTimeout(cur.timer);
            if (t === cur) t = null;
            hideTip();
            if (cur.sent && !cur.noAny) {
              if (!cur.noMouse) fire("mouseup", hover || cur.down, cur.x, cur.y, { button: 0, buttons: 0, detail: cur.detail });
              setHover(null, cur.x, cur.y, true);
            }
            lastClick = { t: -1e9, x: 0, y: 0, n: 0 };
            if (DEBUG) log("cancel " + why);
          };
          // §2.1 두 번째 손가락: 앞 손가락의 누름을 그 자리에서 끝낸다. 끌기·가리키기 중이었으면 mouseup 만, 탭이었으면 click 까지
          const handOff = (cur) => {
            clearTimeout(cur.timer);
            if (!cur.started) start(cur);
            if (DEBUG) log("hand off");
            finish(cur);
          };
          const holdNow = (cur) => {
            if (t !== cur || cur.cancelled || cur.drag || !cur.sent || cur.noAny) return;
            cur.hold = true;
            post("straw", { op: "hold" });
            showTipFor(hover, cur.x, cur.y);
          };
          const tag = (el) => el && el.tagName ? el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") : String(el);

          const isFinger = (e) => e.pointerType === "touch" || e.pointerType === "pen";
          addEventListener("pointerdown", (e) => {
            if (!e.isTrusted) return;
            lastType = e.pointerType;
            if (!isFinger(e)) { converted = false; return; }
            const prev = t;
            if (prev && !prev.finished && !prev.cancelled) {
              // 앞 손가락이 아직 눌려 있음(또는 뗐는데 마무리 전): 그 누름을 끝내고 새 손가락이 마우스가 된다.
              // 첫 손가락(isPrimary)인데 앞 손가락을 떼지 않았다면 pointerup 을 놓친 것이라 버린다
              if (prev.up || !e.isPrimary) handOff(prev); else cancel(prev, "stale");
            }
            const pass = isPass(e.target);
            converted = !pass;
            if (pass) { t = null; return; }
            blurField(e.target);
            const cur = { id: e.pointerId, x0: e.clientX, y0: e.clientY, x: e.clientX, y: e.clientY, pd: e, ts: null, te: null,
                          target: e.target, capture: null, drag: false, hold: false, sent: false, cancelled: false, detail: 1,
                          started: false, finished: false, up: false };
            t = cur;
            cur.timer = setTimeout(() => holdNow(cur), HOLD_MS);
            defer(() => start(cur));
          }, { capture: true });
          addEventListener("pointermove", (e) => {
            if (!e.isTrusted) return;
            if (!isFinger(e)) { lastType = e.pointerType; converted = false; realMove(e); return; }
            lastType = e.pointerType;
            const cur = t;
            if (!cur || e.pointerId !== cur.id || cur.cancelled) return;
            cur.x = e.clientX; cur.y = e.clientY;
            if (!cur.drag && !cur.hold && Math.hypot(cur.x - cur.x0, cur.y - cur.y0) > slop()) { cur.drag = true; clearTimeout(cur.timer); }
            if (cur.sent && !cur.noAny) move(cur);
          }, { capture: true });
          const ended = (e) => {
            if (!e.isTrusted || !isFinger(e)) return;
            const cur = t;
            if (!cur || e.pointerId !== cur.id) return;
            clearTimeout(cur.timer);
            if (e.type === "pointercancel") { cancel(cur, "pointercancel"); return; }
            cur.x = e.clientX; cur.y = e.clientY;
            cur.up = true;
            defer(() => finish(cur));
          };
          addEventListener("pointerup", ended, { capture: true });
          addEventListener("pointercancel", ended, { capture: true });
          addEventListener("gotpointercapture", (e) => { if (t && e.pointerId === t.id) t.capture = e.target; }, { capture: true, passive: true });
          // 이 touch 이벤트가 지금 손가락 것인가. 손가락이 여럿이면 바뀐 손가락의 자리로 가린다 (포인터 id 와 touch id 는 다르다)
          const mine = (e, x, y) => {
            const ch = e.changedTouches;
            if (!ch || ch.length === 0) return false;
            if (ch.length === 1 && e.touches.length <= 1) return true;
            for (let i = 0; i < ch.length; i++) if (Math.abs(ch[i].clientX - x) < 3 && Math.abs(ch[i].clientY - y) < 3) return true;
            return false;
          };
          addEventListener("touchstart", (e) => { if (e.isTrusted && t && !t.ts && mine(e, t.x0, t.y0)) t.ts = e; }, { capture: true, passive: true });
          // pointerup 이 touchend 보다 먼저 온다. 뗀 손가락의 touchend 만 기록한다
          addEventListener("touchend", (e) => { if (e.isTrusted && t && t.up && !t.te && mine(e, t.x, t.y)) t.te = e; }, { capture: true, passive: true });
          addEventListener("touchstart", (e) => { if (e.isTrusted && t && t.ts === e) start(t); }, { passive: true });
          addEventListener("touchend", (e) => { if (e.isTrusted && t && t.te === e && t.up) { const cur = t; start(cur); finish(cur); } }, { passive: true });

          // WebKit 이 손가락 탭 뒤에 만드는 진짜 마우스 이벤트는 게임에 보내지 않는다 (직접 만든 것과 겹친다)
          for (const type of ["mouseover", "mouseout", "mouseenter", "mouseleave", "mousemove", "mousedown", "mouseup", "click", "dblclick", "contextmenu"]) {
            addEventListener(type, (e) => {
              if (!e.isTrusted || !converted || (lastType !== "touch" && lastType !== "pen")) return;
              if (type === "click" && e.detail === 0) return;   // 키보드로 누른 click
              e.stopImmediatePropagation();
              if (e.cancelable) e.preventDefault();
            }, { capture: true });
          }

          // 진짜 마우스: 이벤트는 만들지 않고 가리키기 표시와 말풍선만
          let realTip = 0;
          const realMove = (e) => {
            if (e.pointerType !== "mouse") return;
            clearTimeout(realTip);
            if (tipFor && hover !== e.target) hideTip();
            const x = e.clientX, y = e.clientY;
            if (!e.buttons) realTip = setTimeout(() => showTipFor(hover, x, y), TIP_MS);
          };
          addEventListener("mouseover", (e) => { if (e.isTrusted && lastType === "mouse") setHover(e.target, e.clientX, e.clientY, false); }, { capture: true, passive: true });
          addEventListener("mouseout", (e) => { if (e.isTrusted && lastType === "mouse" && !e.relatedTarget) { setHover(null, 0, 0, false); hideTip(); } }, { capture: true, passive: true });
          addEventListener("mousedown", (e) => { if (e.isTrusted && lastType === "mouse") { clearTimeout(realTip); hideTip(); } }, { capture: true, passive: true });

          // §4 title 말풍선: 닫힌 shadow root 안, 가장 위, 손가락이 닿지 않는다
          let tipHost = null, tipBox = null, tipFor = null;
          const ensureTip = () => {
            if (tipHost && tipHost.isConnected) return;
            tipHost = document.createElement("bingsu-straw-tip");
            for (const [k, v] of [["position", "fixed"], ["left", "0"], ["top", "0"], ["width", "0"], ["height", "0"], ["margin", "0"],
                                  ["z-index", "2147483647"], ["pointer-events", "none"], ["display", "block"], ["transform", "none"]]) tipHost.style.setProperty(k, v, "important");
            const root = tipHost.attachShadow({ mode: "closed" });
            const style = document.createElement("style");
            style.textContent = ".tip{position:fixed;display:none;box-sizing:border-box;white-space:pre-line;overflow-wrap:anywhere;"
              + "font-family:-apple-system,'Apple SD Gothic Neo',sans-serif;font-weight:500;color:#1b2a41;background:rgba(244,248,255,.97);"
              + "box-shadow:0 2px 10px rgba(0,0,0,.28);pointer-events:none;text-align:left}"
              + "@media (prefers-color-scheme: dark){.tip{color:#eef4ff;background:rgba(30,42,61,.97)}}";
            tipBox = document.createElement("div");
            tipBox.className = "tip";
            root.append(style, tipBox);
            document.documentElement.appendChild(tipHost);
          };
          const titleOf = (el) => {
            for (let n = el, i = 0; n && i < 200; n = up(n), i++) {
              const s = n.getAttribute && n.getAttribute("title");
              if (s && s.trim()) return { owner: n, text: s.trim().slice(0, TIP_MAX) };
            }
            return null;
          };
          const showTipFor = (el, x, y) => {
            const found = el ? titleOf(el) : null;
            if (!found) { hideTip(); return; }
            if (tipFor === found.owner) return;
            ensureTip();
            tipFor = found.owner;
            const k = Math.max(0.05, scale);
            const b = tipBox.style;
            b.fontSize = (13 / k) + "px"; b.lineHeight = "1.35"; b.padding = (6 / k) + "px " + (9 / k) + "px";
            b.borderRadius = (8 / k) + "px"; b.maxWidth = Math.min(innerWidth * 0.9, 300 / k) + "px";
            tipBox.textContent = found.text;
            b.left = "0px"; b.top = "0px"; b.display = "block";
            const w = tipBox.offsetWidth, h = tipBox.offsetHeight;
            const v = { x: 0, y: 0, w: innerWidth, h: innerHeight };
            const r = found.owner.getBoundingClientRect();
            const gap = 8 / k, finger = 34 / k, pad = 4 / k;
            // 손가락에 가리지 않게 위쪽, 자리가 없으면 아래쪽. 보이는 영역 밖으로 나가지 않게
            let top = Math.min(r.top, y - finger) - gap - h;
            if (top < v.y + pad) top = Math.max(r.bottom, y + finger) + gap;
            top = Math.max(v.y + pad, Math.min(top, v.y + v.h - h - pad));
            const left = Math.max(v.x + pad, Math.min(x - w / 2, v.x + v.w - w - pad));
            b.left = left + "px"; b.top = top + "px";
          };
          const hideTip = () => { tipFor = null; if (tipBox) tipBox.style.display = "none"; };

          // §3 CSS :hover → [data-bingsu-hover]. 같은 출처 스타일시트 전부, @media·@supports·@layer 안까지, 나중에 더해지는 것도
          let failed = 0, mediaFixed = 0, unreadable = 0, reported = "";
          const seen = new WeakSet();
          const HOVER = /:hover(?![\w-])/g;
          const fixMedia = (r) => {
            let m; try { m = r.media.mediaText; } catch (e) { return; }
            if (!/hover|pointer/.test(m)) return;
            // "마우스가 있는 기기" 조건을 PC 처럼 (37 의 matchMedia 흉내와 같게)
            const n = m.replace(/\(\s*(any-)?hover\s*:\s*hover\s*\)|\(\s*(any-)?hover\s*\)|\(\s*(any-)?pointer\s*:\s*fine\s*\)/g, "(min-width: 0px)")
                       .replace(/\(\s*(any-)?hover\s*:\s*none\s*\)|\(\s*(any-)?pointer\s*:\s*(coarse|none)\s*\)/g, "(max-width: 0px)");
            if (n !== m) { try { r.media.mediaText = n; mediaFixed++; } catch (e) {} }
          };
          const fixRules = (list, depth) => {
            if (!list || depth > 12) return;
            for (let i = 0; i < list.length; i++) {
              const r = list[i];
              if (typeof r.selectorText === "string" && r.selectorText.indexOf(":hover") >= 0) {
                const want = r.selectorText.replace(HOVER, "[" + ATTR + "]");
                try { r.selectorText = want; } catch (e) {}
                if (r.selectorText.indexOf(":hover") >= 0) { failed++; if (DEBUG && failed <= 5) log("hover rule kept " + r.selectorText.slice(0, 120)); } else hoverRules++;
              }
              if (r.media) fixMedia(r);
              if (r.styleSheet) scanSheet(r.styleSheet, depth + 1);
              let inner = null; try { inner = r.cssRules; } catch (e) {}
              if (inner && inner.length) fixRules(inner, depth + 1);
            }
          };
          const scanSheet = (sh, depth) => {
            if (!sh || seen.has(sh)) return;
            let rules; try { rules = sh.cssRules; } catch (e) { seen.add(sh); unreadable++; return; }
            seen.add(sh);
            fixRules(rules, depth || 0);
          };
          let scanQueued = false;
          const scan = () => {
            scanQueued = false;
            const before = hoverRules;
            for (const sh of Array.from(document.styleSheets)) scanSheet(sh, 0);
            if (before === 0 && hoverRules > 0) markHoverNow();
            const s = "hover rules=" + hoverRules + " failed=" + failed + " media=" + mediaFixed + " unreadable=" + unreadable;
            if (s !== reported) { reported = s; log(s); }
          };
          const queueScan = () => { if (!scanQueued) { scanQueued = true; setTimeout(scan, 0); } };
          new MutationObserver((muts) => {
            for (const m of muts) for (const n of m.addedNodes) {
              if (n.nodeType !== 1 || n === tipHost) continue;
              if (n.nodeName === "STYLE") queueScan();
              else if (n.nodeName === "LINK") n.addEventListener("load", queueScan, { once: true });
              else if (n.firstElementChild && n.querySelector("style, link")) { queueScan(); for (const l of n.querySelectorAll("link")) l.addEventListener("load", queueScan, { once: true }); }
            }
          }).observe(document, { childList: true, subtree: true });
          document.addEventListener("DOMContentLoaded", queueScan);
          addEventListener("load", queueScan);

          window.__bingsuStraw = {
            setScale(k) { if (Number.isFinite(k) && k > 0) scale = k; },
            cancel() { if (t) cancel(t, "native"); },
          };
          if (DEBUG) log("ready");
        })();
        """#
    }
}
