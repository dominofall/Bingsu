import SwiftUI
import WebKit
import AVFoundation
import CryptoKit

/// 유리그릇: WKWebView 러너. Electron(로컬) 게임과 배달(웹 URL) 게임을 담는다.
struct GlassBowl: UIViewRepresentable {
    let dish: Dish
    let thermometer: Thermometer
    let freezer: Freezer
    /// 화질 단계. 웹뷰를 만들 때만 읽으므로 바꾸면 다음 실행부터 적용된다
    var quality: Quality = .high
    /// 웹뷰를 만들 때의 프레임 제한 (실행 중 변경은 `__bingsu.setFpsCap`)
    var fpsCap: Int? = nil
    @Binding var webView: WKWebView?
    /// 웹 게임이 다른 사이트(구글·디스코드 로그인 등)로 넘어가려 하면 여기에 담아 팝업 시트로 띄운다
    @Binding var authRequest: AuthRequest?
    /// 홈에 숨어 멈춰 둔 상태인가. 웹 프로세스가 죽어 다시 불러왔을 때 다시 멈추는 데 쓴다
    var paused = false
    /// 게임이 처음부터 다시 떴을 때 (기록·안내용)
    var onRestart: (PerfRestart.Kind) -> Void = { _ in }
    /// 게임이 스스로 끝냄 (MV·MZ 의 nw.App.quit·window.close → 일시정지 화면의 "게임 종료"와 같게)
    var onQuit: () -> Void = {}
    /// 팥빙수 게임이 정한 창 크기(레이아웃 크기, CSS 픽셀). 컨테이너가 웹뷰를 이 크기로 만들고 줄여 그린다
    var onPageSize: (CGSize) -> Void = { _ in }
    /// 팥빙수 게임의 터치 조작(빨대): 화면 pt ÷ CSS px. title 말풍선 글자를 화면에서 읽을 크기로 맞추는 데 쓴다 (명세 §4)
    var strawScale: CGFloat? = nil

    func makeCoordinator() -> Coordinator { Coordinator(dish: dish, thermometer: thermometer, freezer: freezer) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // 게임별 영구 저장소 (웹 게임 로그인·세이브 유지)
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID(for: dish))

        let handler: WKURLSchemeHandler?
        let mvmz = dish.recipe == .rpgMakerMV ? dish.mvmz : nil
        let redBean = dish.isRedBean ? dish.electron : nil
        if redBean != nil {
            // 새 모양 Electron: /app 은 게임 폴더 읽기, /userData 만 저장 데이터 폴더로 쓰기. 켜기 전에 save.json 을 파일로 풀어 둔다
            IceTray.sync(dish, allowUnpack: true)
            let h = RedBeanSchemeHandler(gameRoot: dish.location, saves: freezer.directory, label: dish.id)
            config.setURLSchemeHandler(h, forURLScheme: RedBeanSchemeHandler.scheme)
            handler = h
        } else if dish.recipe == .electron {
            let h = PokemonSchemeHandler(gameRoot: dish.location)
            config.setURLSchemeHandler(h, forURLScheme: PokemonSchemeHandler.scheme)
            handler = h
        } else if dish.recipe == .rpgMakerMV {
            // RPG Maker MV·MZ: 게임 루트 읽기 + save/ 만 저장 데이터 폴더로 쓰기. 켜기 전에 save.json(iCloud·백업 되돌리기)을 파일로 풀어 둔다
            IceTray.sync(dish, allowUnpack: true)
            let h = GreenTeaSchemeHandler(gameRoot: dish.gameRoot, saves: freezer.directory, label: dish.id)
            config.setURLSchemeHandler(h, forURLScheme: GreenTeaSchemeHandler.scheme)
            handler = h
        } else { handler = nil }
        context.coordinator.handler = handler

        let ucc = config.userContentController
        let prefix = freezer.keyPrefix
        // MV·MZ 는 저장을 파일(save/ → Saves/)로 하므로 localStorage 스냅샷을 쓰지 않는다 (얼음틀이 save.json 에 묶는다)
        // 팥빙수 게임도 파일(userData/)로 저장한다. localStorage 는 게임별 웹 저장소에만 남는다 (구현 기록)
        let freezerEnabled = !dish.isRemote && dish.recipe != .rpgMakerMV && redBean == nil
        if dish.knownWeb == .pokerogue {
            // 배경음악을 낮은 표본율로 풀어 메모리 쌓임을 줄인다 (BowlScripts.musicDiet, 다른 소리 스크립트보다 먼저)
            let rate = (DishPrefsStore.shared.prefs(for: dish.id).musicRate ?? .default).rawValue
            ucc.addUserScript(WKUserScript(source: BowlScripts.musicDiet(rate: rate), injectionTime: .atDocumentStart, forMainFrameOnly: true))
            // 한 번 받은 소리·그림·JSON 을 다시 받지 않게 저장해 둔다 (BowlScripts.audioCache, 이 게임 설정에서 끌 수 있음)
            let cacheOn = DishPrefsStore.shared.prefs(for: dish.id).audioCache != false
            ucc.addUserScript(WKUserScript(source: BowlScripts.audioCache(on: cacheOn), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        // Ogg Vorbis 디코더 + 폴리필 (게임 모듈보다 먼저)
        if let url = Bundle.main.url(forResource: "ogg-vorbis-decoder.min", withExtension: "js"),
           let lib = try? String(contentsOf: url, encoding: .utf8) {
            ucc.addUserScript(WKUserScript(source: lib, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            ucc.addUserScript(WKUserScript(source: BowlScripts.oggVorbisPolyfill(lib: lib), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        ucc.addUserScript(WKUserScript(source: BowlScripts.atDocumentStart(restore: freezerEnabled ? freezer.loadLocalStorage() : nil,
                                                                           keyPrefix: prefix, freezer: freezerEnabled,
                                                                           desktopSpoof: !dish.isRemote,
                                                                           renderScale: quality.renderScale, fpsCap: fpsCap,
                                                                           volume: BingsuApp.gameVolume, keysToDocument: mvmz != nil || redBean != nil),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let redBean {
            // Electron 흉내: 메인 스크립트를 먼저 돌리고 require('electron')·Node 를 준비한다 (BowlScripts.electronShim)
            ucc.addUserScript(WKUserScript(source: BowlScripts.electronShim(redBean), injectionTime: .atDocumentStart, forMainFrameOnly: true))
            // <audio> 의 ogg·일시정지·음량 (BowlScripts.mediaShim)
            ucc.addUserScript(WKUserScript(source: BowlScripts.mediaShim(volume: BingsuApp.gameVolume), injectionTime: .atDocumentStart, forMainFrameOnly: true))
            ucc.add(context.coordinator, name: "redbean")
            context.coordinator.onPageSize = onPageSize
            // 터치 조작: 손가락 → PC 마우스, :hover, title 말풍선 (BowlScripts.strawShim, 명세 IMPLEMENTATION-touch.md)
            ucc.addUserScript(WKUserScript(source: BowlScripts.strawShim(debug: DevEnv["BINGSU_TAPDEBUG"] == "1"),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
            ucc.add(context.coordinator, name: "straw")
            NSLog("[Bowl] straw on")
        }
        if let mvmz {
            // NW.js 흉내: 엔진이 PC 처럼 save/ 에 파일로 저장하게 (BowlScripts.nwShim)
            ucc.addUserScript(WKUserScript(source: BowlScripts.nwShim(engine: mvmz.engine), injectionTime: .atDocumentStart, forMainFrameOnly: true))
            if DishPrefsStore.shared.prefs(for: dish.id).pixelSharp != false {
                ucc.addUserScript(WKUserScript(source: BowlScripts.pixelatedCSS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
            ucc.add(context.coordinator, name: "mv")
        }
        ucc.addUserScript(WKUserScript(source: BowlScripts.sfxWatch, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // 웹 소리(Web Audio)는 WebKit 이 앱 오디오 세션과 따로 정해 무음 스위치를 따른다. 페이지의 Audio Session API 와
        // 무음 <audio> 로 "무음 모드에서도 소리 재생"(게임별 → 전역)과 같게 맞춘다 (BowlScripts.silentMode)
        ucc.addUserScript(WKUserScript(source: BowlScripts.silentMode(playInSilent: BingsuApp.playInSilent(for: dish.id)),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        context.coordinator.onExternal = { url in DispatchQueue.main.async { authRequest = AuthRequest(url: url) } }
        context.coordinator.keyPrefix = prefix
        context.coordinator.freezerEnabled = freezerEnabled
        ucc.addUserScript(WKUserScript(source: BowlScripts.fullscreenCSS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if DevEnv["BINGSU_KEYDEBUG"] == "1" {
            ucc.addUserScript(WKUserScript(source: "window.__bingsuKeyDebug = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if DevEnv["BINGSU_TAPDEBUG"] == "1" {
            // 디버그: 탭이 페이지의 어디(CSS 픽셀)에 어떤 요소로 들어가는지 (탭 자리 확인용)
            let js = """
            (() => { const post = (m) => { try { window.webkit.messageHandlers.bowl.postMessage({ event: "tap", msg: m }); } catch (e) {} };
              const name = (t) => t && t.tagName ? t.tagName.toLowerCase() + (t.id ? "#" + t.id : "") + (typeof t.className === "string" && t.className ? "." + t.className.trim().split(/\\s+/).slice(0, 3).join(".") : "") : String(t);
              for (const ty of ["touchstart", "touchend", "pointerdown", "pointerup", "mouseover", "mousedown", "click"]) addEventListener(ty, (e) => { const p = e.touches ? (e.changedTouches[0] || {}) : e; post(ty + " t=" + Math.round(performance.now()) + " " + Math.round(p.clientX) + "," + Math.round(p.clientY) + " " + name(e.target) + " view=" + innerWidth + "x" + innerHeight); }, { capture: true, passive: true }); })();
            """
            ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if dish.knownWeb == .pokerogue {
            // 포켓로그 자체 터치 패드는 숨기고 빙수 가상 패드 입력을 그 버튼의 리스너로 넣는다
            ucc.addUserScript(WKUserScript(source: BowlScripts.pokerogueBridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        for name in ["freezer", "thermometer", "bowl", "rumble", "sfx"] { ucc.add(context.coordinator, name: name) }
        #if DEBUG
        // 디버그 빌드: 포켓로그 멈춤·다시 불러옴 측정 (Documents/Diag)
        if dish.knownWeb == .pokerogue || mvmz != nil, let log = DiagLog(dishID: dish.id) {
            ucc.addUserScript(WKUserScript(source: BowlScripts.diag, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            ucc.add(context.coordinator, name: "diag")
            context.coordinator.startDiag(log)
        }
        #endif

        // 팥빙수 게임: 처음부터 BrowserWindow 기본 창 크기로 만든다. 크기 0 이면 첫 레이아웃 전에 도는 페이지 스크립트가
        // 기본 레이아웃 폭(980)을 innerWidth 로 읽는다 (시험 게임에서 확인)
        let wv = WKWebView(frame: redBean != nil ? CGRect(x: 0, y: 0, width: 1280, height: 720) : .zero, configuration: config)
        if dish.isRemote { wv.customUserAgent = Self.safariUserAgent }
        // MV·MZ: 휴대폰 UA 면 MV 는 .m4a 를 찾고(PC 판엔 없는 일이 많다) 고정 갱신 간격을 버리며, MZ 는 화면 높이의 90%만 쓴다 → 데스크톱 Safari
        if mvmz != nil || redBean != nil { wv.customUserAgent = Self.desktopSafariUserAgent }
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.scrollView.bounces = false
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.allowsBackForwardNavigationGestures = false
        wv.allowsLinkPreview = false
        wv.isOpaque = false
        wv.backgroundColor = UIColor(red: 0.063, green: 0.094, blue: 0.153, alpha: 1)
        #if DEBUG
        wv.isInspectable = true
        #endif

        if let redBean {
            NSLog("[Bowl] recipe=electron main=\(redBean.main) entry=\(redBean.entry) input=\(redBean.inputStyle.rawValue) saves=\(dish.dataPathApp)")
            let path = redBean.entry.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            Self.loadWhenShown(wv, URLRequest(url: URL(string: "\(RedBeanSchemeHandler.origin)/app/\(path)")!))
        } else if dish.recipe == .electron {
            // 레조넌스는 ?mobile=0 으로 띄워 자체 터치 UI 대신 게임패드 경로를 쓰게 한다 (7.4)
            let query = dish.dataPathApp == "pokemon-resonance" ? "?mobile=0" : ""
            wv.load(URLRequest(url: URL(string: "\(PokemonSchemeHandler.origin)/index.html\(query)")!))
        } else if let mvmz {
            NSLog("[Bowl] recipe=rpgMakerMV engine=\(mvmz.engine.rawValue) root=\(mvmz.root.isEmpty ? "." : mvmz.root) saves=\(dish.dataPathApp)")
            wv.load(URLRequest(url: URL(string: "\(GreenTeaSchemeHandler.origin)/index.html")!))
        } else {
            wv.load(URLRequest(url: dish.location))
        }
        context.coordinator.webView = wv
        DispatchQueue.main.async { webView = wv }
        return wv
    }

    /// 웹뷰가 화면(창)에 붙어 크기를 받은 뒤에 첫 페이지를 연다. 창에 붙기 전에 열면 첫 레이아웃 전에 도는 페이지 스크립트가
    /// 기본 레이아웃 크기(980 폭)를 innerWidth·innerHeight 로 읽는다 (팥빙수 시험 게임에서 확인). 1초가 지나면 그냥 연다
    private static func loadWhenShown(_ wv: WKWebView, _ request: URLRequest, tries: Int = 0) {
        if (wv.window != nil && wv.bounds.width > 0) || tries >= 30 {
            if tries > 0 { NSLog("[Bowl] load after \(tries) wait(s) shown=\(wv.window != nil)") }
            // 한 번 더 미뤄 웹킷이 보이는 크기를 받은 다음에 연다
            DispatchQueue.main.async { wv.load(request) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { loadWhenShown(wv, request, tries: tries + 1) }
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        #if DEBUG
        if context.coordinator.paused != paused { context.coordinator.diag?.write(paused ? "paused" : "resumed") }
        #endif
        context.coordinator.paused = paused
        context.coordinator.onRestart = onRestart
        context.coordinator.onQuit = onQuit
        if dish.isRedBean { context.coordinator.onPageSize = onPageSize }
        if dish.isRedBean, let k = strawScale, k > 0, abs(k - context.coordinator.strawScale) > 0.0005 {
            context.coordinator.strawScale = k
            context.coordinator.pushStrawScale(uiView)
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// WKWebView 기본 UA 에는 "Safari" 토큰이 없어 구글 로그인이 막힌다(disallowed_useragent). 같은 iOS 의 사파리 UA.
    static var safariUserAgent: String {
        let v = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        let major = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "26"
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad; CPU OS \(v) like Mac OS X" : "iPhone; CPU iPhone OS \(v) like Mac OS X"
        return "Mozilla/5.0 (\(device)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    /// 같은 iOS 판의 Mac Safari UA (MV·MZ 가 휴대폰으로 보지 않게)
    static var desktopSafariUserAgent: String {
        let major = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "26"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Safari/605.1.15"
    }

    static func storeID(for dish: Dish) -> UUID { WebStoreID.id(for: WebStoreID.key(for: dish)) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let dish: Dish
        let thermometer: Thermometer
        let freezer: Freezer
        var handler: WKURLSchemeHandler?
        var keyPrefix = ""
        var freezerEnabled = false
        var onExternal: ((URL) -> Void)?
        var onRestart: ((PerfRestart.Kind) -> Void)?
        var onQuit: (() -> Void)?
        var onPageSize: ((CGSize) -> Void)?
        /// 스크립트에 마지막으로 알린 배율 (바뀐 때만 다시 알린다)
        var strawScale: CGFloat = 0
        private let holdHaptic = UIImpactFeedbackGenerator(style: .light)
        private var askingOpen = false
        private var declinedOpens = 0
        var paused = false
        /// 웹 프로세스가 죽어 우리가 reload() 한 직후: 그 새로고침은 "게임이 스스로"로 세지 않는다
        private var crashReloadPending = false
        /// 다시 불러온 페이지가 다 뜨면 멈춤 상태를 되돌린다
        private var repauseOnFinish = false
        let openedAt = Date()

        weak var webView: WKWebView?
        private var observers: [NSObjectProtocol] = []

        init(dish: Dish, thermometer: Thermometer, freezer: Freezer) {
            self.dish = dish; self.thermometer = thermometer; self.freezer = freezer
            super.init()
            // 오디오 끊김·경로 변경을 기록하고, 끝나면 세션을 다시 켜고 게임의 멈춘 소리를 되살린다
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                let reason = (n.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt) ?? 0
                NSLog("[Bowl] audio interruption \(type == .began ? "began" : "ended") reason=\(reason)")
                if type == .ended { MainActor.assumeIsolated { BingsuApp.configureAudioSession() }; self?.kickAudio() }
            })
            observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
                let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
                let outs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
                let s = AVAudioSession.sharedInstance()
                NSLog("[Bowl] audio route reason=\(reason) out=\(outs) io=\(String(format: "%.1f", s.ioBufferDuration * 1000))ms sr=\(Int(s.sampleRate))")   // 포트 종류만 (기기 이름 없음)
                self?.kickAudio()
            })
            observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                NSLog("[Bowl] audio media services reset")
                MainActor.assumeIsolated { BingsuApp.configureAudioSession() }; self?.kickAudio()
            })
            // 다른 앱에 갔다 오면 iOS 가 백그라운드 스냅샷을 찍느라 웹뷰 크기를 잠깐 바꾼다.
            // 그 사이 게임(Phaser)이 작은 크기로 맞춰 둔 채 돌아오는 일이 있어, 돌아올 때 확대 배율과 크기를 다시 맞춘다
            // 설정이나 이 게임 설정에서 "무음 모드에서도 소리 재생"·소리 크기를 바꾸면 페이지에도 바로 적용한다
            observers.append(nc.addObserver(forName: BingsuApp.soundPrefsChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let on = BingsuApp.playInSilent(for: self.dish.id)
                    let vol = BingsuApp.gameVolume
                    let cache = DishPrefsStore.shared.prefs(for: self.dish.id).audioCache != false
                    self.webView?.evaluateJavaScript("window.__bingsuSilentMode && __bingsuSilentMode(\(on)); window.__bingsu && __bingsu.setVolume && __bingsu.setVolume(\(vol));"
                                                     + " window.__bingsuAudioCache && __bingsuAudioCache(\(cache))",
                                                     completionHandler: nil)
                }
            })
            observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refit()
            })
        }

        func refit() {
            guard let wv = webView else { return }
            let sv = wv.scrollView
            NSLog("[Bowl] refit view=\(Int(wv.bounds.width))x\(Int(wv.bounds.height)) zoom=\(String(format: "%.2f", sv.zoomScale))")
            if abs(sv.zoomScale - 1) > 0.001 { sv.setZoomScale(1, animated: false) }
            sv.contentOffset = .zero
            wv.setNeedsLayout(); wv.layoutIfNeeded()
            let js = """
            (() => { const v = window.visualViewport; const c = document.querySelector('canvas');
              const s = innerWidth + 'x' + innerHeight + ' vv=' + (v ? v.width.toFixed(0) + 'x' + v.height.toFixed(0) + '@' + v.scale.toFixed(2) : '-') + (c ? ' canvas=' + c.clientWidth + 'x' + c.clientHeight : '');
              window.scrollTo(0, 0); window.dispatchEvent(new Event('resize')); return s; })()
            """
            wv.evaluateJavaScript(js) { r, _ in NSLog("[Bowl] refit page=\(r ?? "nil")") }
            // 레이아웃이 늦게 자리 잡는 경우를 위해 한 번 더
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak wv] in
                wv?.evaluateJavaScript("window.dispatchEvent(new Event('resize'))", completionHandler: nil)
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        #if DEBUG
        var diag: DiagLog?
        func startDiag(_ log: DiagLog) {
            diag = log
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                self?.diag?.write("MEMORY WARNING")
            })
            observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.diag?.write("thermal \(ProcessInfo.processInfo.thermalState.rawValue)")
            })
            for (n, label) in [(UIApplication.didEnterBackgroundNotification, "background"), (UIApplication.willEnterForegroundNotification, "foreground")] {
                observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.diag?.write(label) })
            }
        }
        #endif

        private func kickAudio() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.webView?.evaluateJavaScript("window.__bingsu && __bingsu.kickAudio && __bingsu.kickAudio()", completionHandler: nil)
            }
        }

        /// 빙수 주입 스크립트(BowlScripts)가 보내는 사건 이름. 릴리스 로그에는 이것만 적는다
        static let bowlEvents: Set<String> = ["audio", "compat", "dpr", "error", "fps", "key", "mv", "ogg", "pad", "prkey", "ready", "redbean", "sfxdbg", "stall", "straw"]

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            // 게임 본 화면에서 온 것만 받는다 (광고·임베드 같은 다른 프레임은 무시)
            guard message.frameInfo.isMainFrame else { return }
            switch message.name {
            case "freezer":
                // 웹 쪽에서 온 값은 신뢰하지 않는다: 원격 게임이면 무시, 키 형식·값 타입·총 크기 검증
                guard freezerEnabled, let body = message.body as? [String: Any],
                      let at = (body["at"] as? NSNumber)?.doubleValue, at.isFinite, at > 0, at < 1e15,
                      let dict = body["data"] as? [String: String], !dict.isEmpty else { return }
                // 게임이 켜진 뒤 설정에서 되돌리기·가져오기를 했으면, 이 화면의 스냅샷으로 덮어쓰지 않는다
                guard !Freezer.wasReplaced(dish.dataPathApp, since: openedAt) else { return }
                var total = 0
                for (k, v) in dict {
                    guard freezer.isValidKey(k) else {
                        NSLog("[Bowl] freezer: rejected key \(k.prefix(40))"); return
                    }
                    total += k.utf8.count + v.utf8.count
                    if total > Freezer.maxBytes { NSLog("[Bowl] freezer: snapshot too large"); return }
                }
                // 파일에 쓴 뒤에만 표식을 같은 시각으로 맞춘다 (다르면 다음 실행 때 파일을 복원)
                if freezer.saveLocalStorage(dict, savedAt: at) {
                    let v = String(Int64(at.rounded()))
                    message.webView?.evaluateJavaScript("try { localStorage.setItem('\(Freezer.markerKey)', '\(v)') } catch (e) {}", completionHandler: nil)
                }
            case "rumble":
                // 게임(신뢰하지 않음)이 요청한 진동: 숫자만 받고 범위를 자른다
                guard let d = message.body as? [String: Any],
                      let ms = (d["duration"] as? NSNumber)?.doubleValue, ms.isFinite,
                      let strong = (d["strong"] as? NSNumber)?.floatValue, strong.isFinite,
                      let weak = (d["weak"] as? NSNumber)?.floatValue, weak.isFinite else { return }
                Task { @MainActor in
                    Rumble.shared.play(strong: min(max(strong, 0), 1), weak: min(max(weak, 0), 1), duration: min(max(ms, 0), 5000) / 1000)
                }
            case "sfx":
                // 게임(신뢰하지 않음)이 재생한 효과음 파일 이름 → 게임별 진동표
                guard let d = message.body as? [String: Any], let raw = d["name"] as? String, raw.count <= 80 else { return }
                let name = raw.lowercased()
                Task { @MainActor in
                    if let hit = RumbleSet.forDish(dish).match(name) {
                        if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[Bowl] sfx \(name) -> rumble") }
                        Rumble.shared.play(hit)
                    } else if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[Bowl] sfx \(name)") }
                }
            case "thermometer":
                // 게임(신뢰하지 않음)이 보낸 수치: 숫자만 받고 범위 검증
                if let d = message.body as? [String: Any],
                   let fps = (d["fps"] as? NSNumber)?.doubleValue, fps.isFinite, fps >= 0, fps <= 500,
                   let p95 = (d["p95"] as? NSNumber)?.doubleValue, p95.isFinite, p95 >= 0, p95 <= 60_000,
                   let st = (d["stutters"] as? NSNumber)?.intValue, st >= 0, st <= 1000 {
                    let audio = Thermometer.AudioStat(d["audio"])
                    Task { @MainActor in self.thermometer.ingest(fps: fps, p95: p95, stutters: st, audio: audio) }
                }
            case "bowl":
                if let d = message.body as? [String: Any] {
                    // 게임이 보낸 문자열이라 길이를 자르고, 릴리스에서는 빙수 스크립트가 보내는 사건 이름만 남긴다
                    func clip(_ v: Any?, _ n: Int) -> String { String(String(describing: v ?? "").prefix(n)) }
                    #if DEBUG
                    NSLog("[Bowl] %@ %@ %@", clip(d["event"], 40), clip(d["msg"], 300), clip(d["src"], 120))
                    #else
                    let ev = d["event"] as? String ?? ""
                    NSLog("[Bowl] %@", Self.bowlEvents.contains(ev) ? ev : "other")
                    #endif
                    // 디버그 자가 테스트: 냉동실 경로 검증 (BINGSU_SELFTEST=1)
                    if (d["event"] as? String) == "ready", DevEnv["BINGSU_SELFTEST"] == "1" {
                        // 덮어쓰기 전에 복원 결과를 먼저 남긴다: 접두사 키 개수와 직전 실행이 남긴 자가 테스트 값
                        let p = keyPrefix
                        let probe = "(() => { const ks = Object.keys(localStorage).filter(k => k.startsWith('\(p)')); "
                            + "const prev = localStorage.getItem('\(p)bingsu-selftest'); "
                            + "localStorage.setItem('\(p)bingsu-selftest', String(Date.now())); __bingsu.flush(); "
                            + "return 'keys=' + ks.length + ' selftest=' + prev; })()"
                        message.webView?.evaluateJavaScript(probe) { r, _ in NSLog("[Bowl] selftest \(r ?? "nil")") }
                        // MV·MZ: 웹뷰 안에서 save/ 밖 쓰기가 실제로 거부되는지 (모두 EACCES·ENOENT 로 던져야 통과)
                        if dish.recipe == .rpgMakerMV {
                            let mvProbe = "(() => { const fs = require('fs'); const bad = []; "
                                + "const tries = [['w','/index.html'],['w','/data/System.json'],['w','/save/../js/main.js'],['w','/save/notes.txt'],"
                                + "['w','/SAVE/x/file1.rpgsave'],['m','/img'],['u','/js/main.js'],['r','/save/../data/System.json']]; "
                                + "for (const [op, p] of tries) { try { if (op === 'w') fs.writeFileSync(p, 'x'); else if (op === 'm') fs.mkdirSync(p + '/new'); "
                                + "else if (op === 'u') fs.unlinkSync(p); else fs.renameSync('/save/file1.rmmzsave', p); bad.push(op + ' ' + p); } catch (e) {} } "
                                + "const ok = fs.existsSync('/data/System.json') && fs.existsSync('/DATA/system.json'); "
                                + "return 'mv write guard ' + (bad.length === 0 && ok ? 'OK' : 'FAIL') + ' tried=' + tries.length + ' leaked=' + JSON.stringify(bad) + ' ci=' + ok; })()"
                            message.webView?.evaluateJavaScript(mvProbe) { r, e in NSLog("[Bowl] selftest \(r ?? e.map { "\($0)" } ?? "nil")") }
                        }
                    }
                }
            case "mv":
                // NW.js 흉내(신뢰하지 않음)가 보낸 요청: 종료와 외부 링크(http·https 만, 사파리로)
                guard dish.recipe == .rpgMakerMV, let d = message.body as? [String: Any], let op = d["op"] as? String else { return }
                if op == "quit" {
                    NSLog("[Bowl] mv quit requested")
                    onQuit?()
                } else if op == "open", let raw = d["url"] as? String, raw.count <= 2000, let url = URL(string: raw), ExternalLink.isWeb(url) {
                    askToOpen(url, from: message.webView)
                }
            case "redbean":
                // Electron 흉내(신뢰하지 않음)가 보낸 요청: 종료, 외부 링크(http·https 만, 묻고 사파리로), 창 크기
                guard dish.isRedBean, let d = message.body as? [String: Any], let op = d["op"] as? String else { return }
                switch op {
                case "quit":
                    NSLog("[Bowl] redbean quit requested")
                    onQuit?()
                case "open":
                    if let raw = d["url"] as? String, raw.count <= 2000, let url = URL(string: raw), ExternalLink.isWeb(url) { askToOpen(url, from: message.webView) }
                case "window":
                    guard let w = (d["w"] as? NSNumber)?.doubleValue, let h = (d["h"] as? NSNumber)?.doubleValue,
                          w.isFinite, h.isFinite, (100...8000).contains(w), (100...8000).contains(h) else { return }
                    NSLog("[Bowl] redbean window \(Int(w))x\(Int(h))")
                    onPageSize?(CGSize(width: w.rounded(), height: h.rounded()))
                default: break
                }
            case "straw":
                // 빨대 스크립트(신뢰하지 않음)의 알림: 가리키기가 된 순간 약한 진동 한 번 (패드 진동 설정을 따른다)
                guard dish.isRedBean, let d = message.body as? [String: Any], (d["op"] as? String) == "hold" else { return }
                Task { @MainActor in
                    if DishPrefsStore.shared.effectivePad(for: self.dish.id).haptics { self.holdHaptic.impactOccurred(intensity: 0.5) }
                }
            #if DEBUG
            case "diag":
                if let s = message.body as? String { diag?.write(String(s.prefix(600))) }
            #endif
            default: break
            }
        }

        // 외부 링크는 Safari 로, 게임은 그대로 유지
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            // 게임이 스스로 새로고침 (location.reload): 기록만 하고 그대로 둔다
            if action.navigationType == .reload, action.targetFrame?.isMainFrame ?? true {
                if crashReloadPending { crashReloadPending = false }
                else {
                    NSLog("[Bowl] game reloaded itself"); onRestart?(.gameReload); repauseOnFinish = paused
                    #if DEBUG
                    diag?.write("GAME RELOADED ITSELF")
                    #endif
                }
            }
            if dish.isRedBean {
                // 게임 출처만. 누른 링크(http·https)는 묻고 사파리로 (shell.openExternal 도 같은 길), 하위 프레임의 about:blank 는 둔다
                if url.scheme == RedBeanSchemeHandler.scheme { return decisionHandler(.allow) }
                if url.scheme == "about", !(action.targetFrame?.isMainFrame ?? true) { return decisionHandler(.allow) }
                if action.navigationType == .linkActivated, ExternalLink.isWeb(url) { askToOpen(url, from: webView) }
                return decisionHandler(.cancel)
            }
            if dish.recipe == .electron {
                return decisionHandler(url.scheme == PokemonSchemeHandler.scheme ? .allow : .cancel)
            }
            if dish.recipe == .rpgMakerMV {
                // 게임 출처만. 누른 링크(http·https)는 사파리로, 하위 프레임의 about:blank 는 둔다
                if url.scheme == GreenTeaSchemeHandler.scheme { return decisionHandler(.allow) }
                if url.scheme == "about", !(action.targetFrame?.isMainFrame ?? true) { return decisionHandler(.allow) }
                if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
                return decisionHandler(.cancel)
            }
            // 다른 사이트로의 이동: 링크 클릭은 사파리로, 로그인 리다이렉트는 팝업 시트로, 그 밖에 게임이 스스로 옮기는 것은 물어본다
            if action.targetFrame?.isMainFrame ?? true {
                switch ExternalLink.route(url, gameHost: dish.location.host, clicked: action.navigationType == .linkActivated) {
                case .stay: break
                case .safari: UIApplication.shared.open(url); return decisionHandler(.cancel)
                case .loginSheet: onExternal?(url); return decisionHandler(.cancel)
                case .ask: askToOpen(url, from: webView); return decisionHandler(.cancel)
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ExternalLink.isWeb(url) { UIApplication.shared.open(url) }
            return nil
        }

        /// 팥빙수 게임의 alert·confirm (Electron dialog.showMessageBox 도 이 길). 다른 게임은 지금처럼 아무것도 띄우지 않는다
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            guard dish.isRedBean, frame.isMainFrame, var top = webView.window?.rootViewController else { return completionHandler() }
            while let next = top.presentedViewController { top = next }
            let alert = UIAlertController(title: nil, message: String(message.prefix(1000)), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler() })
            top.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            guard dish.isRedBean, frame.isMainFrame, var top = webView.window?.rootViewController else { return completionHandler(false) }
            while let next = top.presentedViewController { top = next }
            let alert = UIAlertController(title: nil, message: String(message.prefix(1000)), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler(true) })
            top.present(alert, animated: true)
        }

        /// 게임이 사용자의 손길 없이 연 외부 주소는 실제 주소를 보여 주고 묻는다. 떠 있는 동안 온 요청과 두 번 거절한 뒤의 요청은 버린다
        private func askToOpen(_ url: URL, from webView: WKWebView?) {
            guard !askingOpen, declinedOpens < 2, var top = webView?.window?.rootViewController else { return }
            while let next = top.presentedViewController { top = next }
            askingOpen = true
            let alert = UIAlertController(title: "사파리에서 열까요?", message: url.host ?? url.absoluteString, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "취소", style: .cancel) { [weak self] _ in self?.askingOpen = false; self?.declinedOpens += 1 })
            alert.addAction(UIAlertAction(title: "열기", style: .default) { [weak self] _ in self?.askingOpen = false; UIApplication.shared.open(url) })
            top.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[Bowl] navigation failed: \(error.localizedDescription)")
        }
        /// 웹 콘텐츠 프로세스가 죽음: 대개 iOS 가 메모리 부족으로 정리한 것(게임 중 갑자기 처음 화면으로 돌아가는 원인).
        /// 앱에서 막을 수는 없고, 기록을 남기고 안내한 뒤 다시 불러온다. 죽은 뒤라 마지막 저장 이후(로컬 게임은 최대 5초)는 잃는다.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NSLog("[Bowl] web content process terminated (memory?) — reloading")
            #if DEBUG
            diag?.write("WEB PROCESS KILLED (reload)")
            #endif
            onRestart?(.crash)
            crashReloadPending = true
            repauseOnFinish = paused
            webView.reload()
        }

        @MainActor func pushStrawScale(_ webView: WKWebView) {
            guard strawScale > 0 else { return }
            webView.evaluateJavaScript(String(format: "window.__bingsuStraw&&__bingsuStraw.setScale(%.4f)", strawScale), completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            #if DEBUG
            diag?.write("page loaded")
            #endif
            crashReloadPending = false
            // 페이지를 새로 읽으면 스크립트가 처음부터라 배율을 다시 알린다
            if dish.isRedBean { MainActor.assumeIsolated { pushStrawScale(webView) } }
            guard repauseOnFinish else { return }
            repauseOnFinish = false
            if paused { webView.evaluateJavaScript("window.__bingsu && __bingsu.pause()", completionHandler: nil) }
        }
    }
}

/// 게임 밖 주소를 어디서 열지 정한다. 로그인 시트는 앱 화면처럼 보이므로 실제 로그인 업체와 이 게임 사이트의 하위 주소만 연다.
enum ExternalLink {
    enum Route: Equatable { case stay, safari, loginSheet, ask }

    /// 외부 로그인에 쓰는 업체의 로그인 주소 (정확히 같은 호스트만)
    static let loginHosts: Set<String> = ["accounts.google.com", "discord.com", "appleid.apple.com", "login.microsoftonline.com",
                                          "login.live.com", "github.com", "www.facebook.com"]

    static func isWeb(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    static func route(_ url: URL, gameHost: String?, clicked: Bool) -> Route {
        guard isWeb(url), let host = url.host?.lowercased(), !host.isEmpty else { return .stay }
        let game = gameHost?.lowercased() ?? ""
        if host == game { return .stay }
        if clicked { return .safari }
        let secure = url.scheme?.lowercased() == "https" && (url.port == nil || url.port == 443) && url.user == nil
        // 하위 주소만 같은 사이트로 친다 (a.github.io 와 b.github.io 는 주인이 다를 수 있다)
        let trusted = loginHosts.contains(host) || (!game.isEmpty && host.hasSuffix("." + game))
        return secure && trusted ? .loginSheet : .ask
    }
}

/// 게임별 웹 저장소(쿠키·localStorage) 번호. 한 번 정한 번호는 표에 남겨 바꾸지 않는다.
/// 예전 방식(`legacyID`)은 XOR 이라 `dragon1`·`dragona` 처럼 다른 게임이 같은 번호를 받을 수 있었다. 이미 있던 게임은
/// 로그인·진행이 이어지도록 예전 번호를 표에 옮겨 두고(`adoptLegacy`), 그 뒤에 처음 보는 게임은 SHA-256 으로 만든다.
enum WebStoreID {
    private static let tableKey = "webStoreIDs"
    private static let adoptedKey = "webStoreIDsAdopted"

    /// 아는 웹 게임은 기본 카드 id 를 써서, 릴리스에서 주소로 다시 넣어도 예전 로그인·진행이 이어진다
    static func key(for dish: Dish) -> String { dish.knownWeb?.rawValue ?? dish.id }

    static func id(for key: String) -> UUID {
        var table = UserDefaults.standard.dictionary(forKey: tableKey) as? [String: String] ?? [:]
        let before = table.count
        let id = assign(key, table: &table)
        if table.count != before { UserDefaults.standard.set(table, forKey: tableKey) }
        return id
    }

    /// 이 수정 전에 설치된 게임의 번호를 표로 옮긴다. 켤 때 한 번, 게임 목록을 읽은 뒤에
    static func adoptLegacyOnce(keys: [String]) {
        guard !UserDefaults.standard.bool(forKey: adoptedKey) else { return }
        var table = UserDefaults.standard.dictionary(forKey: tableKey) as? [String: String] ?? [:]
        adoptLegacy(keys, table: &table)
        UserDefaults.standard.set(table, forKey: tableKey)
        UserDefaults.standard.set(true, forKey: adoptedKey)
    }

    static func assign(_ key: String, table: inout [String: String]) -> UUID {
        if let s = table[key], let id = UUID(uuidString: s) { return id }
        let id = hashedID(key)
        table[key] = id.uuidString
        return id
    }

    /// 예전 번호가 겹치면 먼저 나온 게임만 그 번호를 갖고, 나머지는 새 번호를 받는다
    static func adoptLegacy(_ keys: [String], table: inout [String: String]) {
        for key in keys where table[key] == nil {
            let id = legacyID(key).uuidString
            if !table.values.contains(id) { table[key] = id }
        }
    }

    static func hashedID(_ key: String) -> UUID {
        uuid(from: Array(SHA256.hash(data: Data(key.utf8)).prefix(16)))
    }

    static func legacyID(_ key: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in key.utf8.enumerated() { bytes[i % 16] ^= b &+ UInt8(i & 0xff) }
        return uuid(from: bytes)
    }

    private static func uuid(from raw: [UInt8]) -> UUID {
        var bytes = raw
        bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
