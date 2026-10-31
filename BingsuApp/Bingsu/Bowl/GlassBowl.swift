import SwiftUI
import WebKit
import AVFoundation

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

    func makeCoordinator() -> Coordinator { Coordinator(dish: dish, thermometer: thermometer, freezer: freezer) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // 게임별 영구 저장소 (웹 게임 로그인·세이브 유지)
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID(for: dish))

        let handler: PokemonSchemeHandler?
        if dish.recipe == .electron {
            let h = PokemonSchemeHandler(gameRoot: dish.location)
            config.setURLSchemeHandler(h, forURLScheme: PokemonSchemeHandler.scheme)
            handler = h
        } else { handler = nil }
        context.coordinator.handler = handler

        let ucc = config.userContentController
        let prefix = freezer.keyPrefix
        let freezerEnabled = !dish.isRemote
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
                                                                           volume: BingsuApp.gameVolume),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: BowlScripts.sfxWatch, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // 웹 소리(Web Audio)는 WebKit 이 앱 오디오 세션과 따로 정해 무음 스위치를 따른다. 페이지의 Audio Session API 와
        // 무음 <audio> 로 "무음 모드에서도 소리 재생"(게임별 → 전역)과 같게 맞춘다 (BowlScripts.silentMode)
        ucc.addUserScript(WKUserScript(source: BowlScripts.silentMode(playInSilent: BingsuApp.playInSilent(for: dish.id)),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        context.coordinator.onExternal = { url in DispatchQueue.main.async { authRequest = AuthRequest(url: url) } }
        context.coordinator.keyPrefix = prefix
        context.coordinator.freezerEnabled = freezerEnabled
        ucc.addUserScript(WKUserScript(source: BowlScripts.fullscreenCSS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if ProcessInfo.processInfo.environment["BINGSU_KEYDEBUG"] == "1" {
            ucc.addUserScript(WKUserScript(source: "window.__bingsuKeyDebug = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if dish.knownWeb == .pokerogue {
            // 포켓로그 자체 터치 패드는 숨기고 빙수 가상 패드 입력을 그 버튼의 리스너로 넣는다
            ucc.addUserScript(WKUserScript(source: BowlScripts.pokerogueBridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        for name in ["freezer", "thermometer", "bowl", "rumble", "sfx"] { ucc.add(context.coordinator, name: name) }

        let wv = WKWebView(frame: .zero, configuration: config)
        if dish.isRemote { wv.customUserAgent = Self.safariUserAgent }
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

        if dish.recipe == .electron {
            // 레조넌스는 ?mobile=0 으로 띄워 자체 터치 UI 대신 게임패드 경로를 쓰게 한다 (7.4)
            let query = dish.dataPathApp == "pokemon-resonance" ? "?mobile=0" : ""
            wv.load(URLRequest(url: URL(string: "\(PokemonSchemeHandler.origin)/index.html\(query)")!))
        } else {
            wv.load(URLRequest(url: dish.location))
        }
        context.coordinator.webView = wv
        DispatchQueue.main.async { webView = wv }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.paused = paused
        context.coordinator.onRestart = onRestart
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

    static func storeID(for dish: Dish) -> UUID {
        // dish.id 에서 안정적인 UUID 생성. 아는 웹 게임은 기본 카드 id 를 써서, 릴리스에서 주소로 다시 넣어도 예전 로그인·진행이 이어진다
        let key = dish.knownWeb?.rawValue ?? dish.id
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in key.utf8.enumerated() { bytes[i % 16] ^= b &+ UInt8(i & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let dish: Dish
        let thermometer: Thermometer
        let freezer: Freezer
        var handler: PokemonSchemeHandler?
        var keyPrefix = ""
        var freezerEnabled = false
        var onExternal: ((URL) -> Void)?
        var onRestart: ((PerfRestart.Kind) -> Void)?
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
                    self.webView?.evaluateJavaScript("window.__bingsuSilentMode && __bingsuSilentMode(\(on)); window.__bingsu && __bingsu.setVolume && __bingsu.setVolume(\(vol))",
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

        private func kickAudio() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.webView?.evaluateJavaScript("window.__bingsu && __bingsu.kickAudio && __bingsu.kickAudio()", completionHandler: nil)
            }
        }

        /// 빙수 주입 스크립트(BowlScripts)가 보내는 사건 이름. 릴리스 로그에는 이것만 적는다
        static let bowlEvents: Set<String> = ["audio", "dpr", "error", "fps", "key", "ogg", "pad", "prkey", "ready", "sfxdbg", "stall"]

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
                        if ProcessInfo.processInfo.environment["BINGSU_KEYDEBUG"] == "1" { NSLog("[Bowl] sfx \(name) -> rumble") }
                        Rumble.shared.play(hit)
                    } else if ProcessInfo.processInfo.environment["BINGSU_KEYDEBUG"] == "1" { NSLog("[Bowl] sfx \(name)") }
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
                    if (d["event"] as? String) == "ready", ProcessInfo.processInfo.environment["BINGSU_SELFTEST"] == "1" {
                        // 덮어쓰기 전에 복원 결과를 먼저 남긴다: 접두사 키 개수와 직전 실행이 남긴 자가 테스트 값
                        let p = keyPrefix
                        let probe = "(() => { const ks = Object.keys(localStorage).filter(k => k.startsWith('\(p)')); "
                            + "const prev = localStorage.getItem('\(p)bingsu-selftest'); "
                            + "localStorage.setItem('\(p)bingsu-selftest', String(Date.now())); __bingsu.flush(); "
                            + "return 'keys=' + ks.length + ' selftest=' + prev; })()"
                        message.webView?.evaluateJavaScript(probe) { r, _ in NSLog("[Bowl] selftest \(r ?? "nil")") }
                    }
                }
            default: break
            }
        }

        // 외부 링크는 Safari 로, 게임은 그대로 유지
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            // 게임이 스스로 새로고침 (location.reload): 기록만 하고 그대로 둔다
            if action.navigationType == .reload, action.targetFrame?.isMainFrame ?? true {
                if crashReloadPending { crashReloadPending = false }
                else { NSLog("[Bowl] game reloaded itself"); onRestart?(.gameReload); repauseOnFinish = paused }
            }
            if dish.recipe == .electron {
                return decisionHandler(url.scheme == PokemonSchemeHandler.scheme ? .allow : .cancel)
            }
            // 다른 사이트로의 이동: 링크 클릭은 사파리로, 그 외(로그인 리다이렉트 등 메인 프레임)는 팝업 시트로
            if url.host != dish.location.host, action.targetFrame?.isMainFrame ?? true, url.scheme?.hasPrefix("http") == true {
                if action.navigationType == .linkActivated { UIApplication.shared.open(url) } else { onExternal?(url) }
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, url.scheme?.hasPrefix("http") == true { UIApplication.shared.open(url) }
            return nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[Bowl] navigation failed: \(error.localizedDescription)")
        }
        /// 웹 콘텐츠 프로세스가 죽음: 대개 iOS 가 메모리 부족으로 정리한 것(게임 중 갑자기 처음 화면으로 돌아가는 원인).
        /// 앱에서 막을 수는 없고, 기록을 남기고 안내한 뒤 다시 불러온다. 죽은 뒤라 마지막 저장 이후(로컬 게임은 최대 5초)는 잃는다.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NSLog("[Bowl] web content process terminated (memory?) — reloading")
            onRestart?(.crash)
            crashReloadPending = true
            repauseOnFinish = paused
            webView.reload()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            crashReloadPending = false
            guard repauseOnFinish else { return }
            repauseOnFinish = false
            if paused { webView.evaluateJavaScript("window.__bingsu && __bingsu.pause()", completionHandler: nil) }
        }
    }
}
