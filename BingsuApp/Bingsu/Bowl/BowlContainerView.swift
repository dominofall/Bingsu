import SwiftUI
import WebKit
import GameController

/// 러너 화면: 전체화면 그릇 + 온도계 HUD + 숟가락 + 나가기.
struct BowlContainerView: View {
    let dish: Dish
    /// false 면 홈(게임 목록) 뒤에 숨어 일시정지 상태. 웹뷰는 살아 있다.
    var visible = true
    var onHome: () -> Void = {}
    let onClose: () -> Void

    @StateObject private var thermometer = Thermometer()
    @StateObject private var spoon = SpoonController()
    /// 성능 기록: 화면 표시와 상관없이 항상 남긴다 (`Documents/Perf/<id>.json`)
    @StateObject private var recorder: PerfRecorder
    /// 이번 실행의 화질 (웹뷰를 만들 때 정해지므로 실행 중에는 바뀌지 않는다)
    private let quality: Quality
    /// 프레임 제한 (이 게임 설정 › 성능, 일시정지 화면에서도 바꿈). nil = 제한 없음
    @State private var baseFpsCap: Int?
    /// 프레임 제한이 "자동"이면 기기가 뜨거워질 때 30 으로 낮춘다
    @State private var autoFps: Bool
    @State private var heatCapped = false
    @State private var longSpoon: LongSpoon?
    @State private var teaSpoon: TeaSpoon?   // 애플워치 (Spoon/TeaSpoon.swift)
    @State private var toast: String?
    @State private var webView: WKWebView?
    @State private var controllerConnected = BowlContainerView.realGamepadConnected()
    @ObservedObject private var watch = TeaSpoonLink.shared
    @AppStorage(TeaSpoonLink.enabledKey) private var watchEnabled = true
    @ObservedObject private var table = TableSpoonLink.shared
    @AppStorage(TableSpoonLink.enabledKey) private var tableEnabled = true

    /// 실제 게임패드(확장 게임패드 프로필)만 "컨트롤러 연결됨"으로 본다. 키보드·마우스·시뮬레이터 장치는 제외.
    static func realGamepadConnected() -> Bool {
        let pads = GCController.controllers()
        return pads.contains { $0.extendedGamepad != nil && !$0.isSnapshot }
    }
    @AppStorage("bingsu.showPerformance") private var showHUD = false
    @AppStorage(AudioDiagHUD.key) private var audioDiag = false
    /// 웹 게임은 자체 터치 UI 를 쓰므로 가상 패드를 기본으로 숨긴다 (일시정지 시트에서 켤 수 있음)
    @State private var showSpoon: Bool
    /// 컨트롤러가 연결돼 있어도 사용자가 "가상 패드 보기"를 고르면 보여준다 (BINGSU_FORCE_PAD=1 로도 켬)
    @State private var padForced = DevEnv["BINGSU_FORCE_PAD"] == "1"
    /// 일시정지 화면 (PauseBoard)
    @State private var showMenu = false
    @State private var pauseFocus: PauseItem?
    @State private var lastBackup: Date?
    @State private var showSettings = false
    /// 배치 편집 (일시정지 화면 › 배치 편집). 게임은 멈춘 채 그 위에 편집기를 띄운다
    @State private var showEditor = false
    @State private var authRequest: AuthRequest?
    @AppStorage("bingsu.menuButton") private var menuButtonRaw = MenuButtonPlace.pad.rawValue
    private var menuButtonPlace: MenuButtonPlace {
        // 디버그: BINGSU_MENU_BUTTON=topRight|topLeft|pad 로 강제 (스크린샷 자동화)
        if let e = DevEnv["BINGSU_MENU_BUTTON"], let p = MenuButtonPlace(rawValue: e) { return p }
        // 한손 배치는 설정과 상관없이 패드 구역 오른쪽 위에 고정 (2026-10-31 사용자 결정, 자리는 makeOneHand)
        if padPrefs.kind == .oneHand { return .pad }
        return MenuButtonPlace(rawValue: menuButtonRaw) ?? .pad
    }
    @ObservedObject private var prefsStore = DishPrefsStore.shared
    // 전역 패드 설정이 바뀌면 다시 그리도록 키들을 관찰한다
    @AppStorage("spoon.kind") private var gKind = PadKind.simple.rawValue
    @AppStorage("spoon.scale") private var gScale = 1.0
    @AppStorage("spoon.opacity") private var gOpacity = 0.55
    @AppStorage("spoon.floatingStick") private var gFloating = true
    @AppStorage("spoon.showLabels") private var gLabels = false
    @AppStorage("spoon.haptics") private var gHaptics = true
    @AppStorage("spoon.leftHanded") private var gLeftHanded = false
    @AppStorage(PadPrefs.skinKey) private var gSkin: String?
    @AppStorage(PadPrefs.layoutsKey) private var gLayouts: Data?
    private var padPrefs: PadPrefs {
        var p = prefsStore.effectivePad(for: dish.id)
        // 기본·레트로·한손 배치에는 LT/RT 가 없다: 트리거를 쓰는 게임은 게임별로 따로 고르지 않았으면 스틱 배치로 연다.
        // 사용자가 배치 편집에서 LT·RT 를 더했으면 그 배치를 그대로 쓴다 (종류가 아니라 배치로 판단)
        if !p.providesTriggers(), CutlerySet.forDish(dish).needsTriggers, prefsStore.prefs(for: dish.id).pad == nil { p.kind = .standard }
        return p
    }
    @Environment(\.scenePhase) private var scenePhase

    private var freezer: Freezer { Freezer(dish: dish) }

    init(dish: Dish, visible: Bool = true, onHome: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.dish = dish; self.visible = visible; self.onHome = onHome; self.onClose = onClose
        let prefs = DishPrefsStore.shared.prefs(for: dish.id)
        let q = prefs.effectiveQuality
        quality = q
        _baseFpsCap = State(initialValue: prefs.baseFpsCap(for: dish))
        _autoFps = State(initialValue: prefs.fpsLimit == nil)
        let rec = PerfRecorder(dishID: dish.id, title: dish.title, quality: q)
        rec.fpsCap = prefs.baseFpsCap(for: dish)
        _recorder = StateObject(wrappedValue: rec)
        // 빙수 매핑이 있는 게임은 가상 패드를 기본 표시, 자체 터치 UI 만 있는 웹 게임은 숨김
        _showSpoon = State(initialValue: !dish.isRemote || CutlerySet.forDish(dish).transport == .gamepad || !CutlerySet.forDish(dish).keys.isEmpty)
    }

    var body: some View {
        ZStack {
            Color(red: 0.063, green: 0.094, blue: 0.153).ignoresSafeArea()
            // 세로 화면: 게임을 위쪽에 16:9 로 붙이고 아래 공간을 패드에 준다. 가로: 전체화면.
            GeometryReader { geo in
                // 게임 웹뷰는 항상 하나만 두고(회전해도 다시 만들지 않음) 자리와 크기만 바꾼다.
                let r = gameRect(geo)
                // 페이지에 보여 줄 크기. 보통은 자리 크기 그대로, 기본 게임 세로는 가로 화면의 게임 크기로 그린 뒤 줄인다
                let page = pageSize(geo.size, rect: r)
                let k = page.width > 0 ? r.width / page.width : 1
                GlassBowl(dish: dish, thermometer: thermometer, freezer: freezer, quality: quality, fpsCap: baseFpsCap, webView: $webView, authRequest: $authRequest,
                          paused: !visible, onRestart: restarted, onQuit: { flush(); onClose() })
                    .frame(width: page.width, height: page.height - refitNudge)
                    .clipShape(RoundedRectangle(cornerRadius: Self.corner / k, style: .continuous))
                    .scaleEffect(k)
                    .position(x: r.midX, y: r.midY)
            }
            .ignoresSafeArea()

            if showSpoon && (!controllerConnected || padForced) && !showEditor { SpoonOverlay(controller: spoon, prefs: padPrefs) }

            if showHUD {
                VStack {
                    HStack { ThermometerHUD(thermometer: thermometer); Spacer() }.padding(.horizontal, 12).padding(.top, 8)
                    // 진단: 지금 눌린 패드 버튼 (가상 패드·실제 컨트롤러 공통)
                    HStack {
                        Text(padDebugText).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.5), in: Capsule())
                        Spacer()
                    }.padding(.horizontal, 12)
                    Spacer()
                }
            }
            if audioDiag {
                VStack {
                    Spacer()
                    HStack { AudioDiagHUD(thermometer: thermometer); Spacer() }.padding(.horizontal, 12).padding(.bottom, 8)
                }
                .allowsHitTesting(false)
            }
            if let toast {
                VStack {
                    Text(toast).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8).background(.black.opacity(0.6), in: Capsule())
                        .padding(.top, 10)
                    Spacer()
                }
                .transition(.opacity)
            }
            // 눈송이(일시정지) 버튼: 설정에 따라 구석(안전 영역 밖) 또는 패드 안. 구석은 패드가 안전 영역 안에만 놓여 안 겹친다.
            if !showMenu && !showEditor { menuButton }
            if showMenu { pauseBoard.zIndex(2) }
            if showEditor {
                SpoonLayoutEditor(prefs: padPrefs, backdrop: .game, target: dish.title,
                                  save: { k, a in setPadHere(padPrefs.withLayout(k, a)) },
                                  onClose: { showEditor = false; openPause() })
                    .zIndex(3)
            }
        }
        .persistentSystemOverlays(visible ? .hidden : .automatic)
        .statusBarHidden(visible)
        .sheet(isPresented: $showSettings) { DishSettingsView(dish: dish) }
        .sheet(item: $authRequest) { req in
            AuthPopupView(dish: dish, url: req.url) { webView?.load(URLRequest(url: dish.location)) }
        }
        .onChange(of: padPrefs.haptics) { _, on in spoon.hapticsEnabled = on }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { nudgeWebViewSize() }
            if phase != .active { flush(); spoon.releaseAll() }
            // 앱이 안 보이면 게임 소리와 무음 <audio> 를 멈춘다. 무음 재생이 돌고 있으면 WebKit 이 백그라운드에서도
            // 게임 소리를 계속 내기 때문 (2026-10-31 실기기). 돌아오면 게임이 보이고 일시정지 화면이 아닐 때만 다시 켠다
            if phase == .background || (phase == .active && visible && !showMenu && !showEditor) {
                setWebAudioHeld(phase != .active)
            }
            if phase == .background { Igloo.shared.afterPlay(dish, stillRunning: true) }
            recorder.setActive(phase == .active && visible)
            showReturnToast()
        }
        .onChange(of: webView) { _, wv in spoon.webView = wv }
        .onChange(of: visible) { _, v in
            if !v && showMenu { closePause(resume: false) }
            if !v { showEditor = false }
            longSpoon?.enabled = v
            teaSpoon?.enabled = v
            TeaSpoonLink.shared.setContext(game: dish.title, state: v ? .playing : .home)
            recorder.setActive(v && scenePhase == .active)
            showReturnToast()
            webView?.evaluateJavaScript("window.__bingsu && __bingsu.\(v ? "resume" : "pause")()", completionHandler: nil)
            webView?.evaluateJavaScript("window.__bingsuSilentHold && __bingsuSilentHold(\(!v))", completionHandler: nil)
        }
        .onAppear {
            spoon.cutlery = CutlerySet.forDish(dish); spoon.webView = webView; spoon.hapticsEnabled = padPrefs.haptics
            if longSpoon == nil { longSpoon = LongSpoon(spoon: spoon) }   // 실제 컨트롤러 → 같은 경로로 입력
            longSpoon?.enabled = visible
            longSpoon?.onHomeButton = { if visible && !showMenu && !showEditor { openPause() } }
            if teaSpoon == nil { teaSpoon = TeaSpoon(spoon: spoon) }      // 애플워치 → 같은 경로로 입력
            teaSpoon?.enabled = visible
            teaSpoon?.onHomeButton = { if visible && !showMenu && !showEditor { openPause() } }
            TeaSpoonLink.shared.setContext(game: dish.title, state: visible ? .playing : .home)
            // 디버그: BINGSU_PAUSE=1 이면 3초 뒤 일시정지 화면을 연다 (시뮬레이터 확인용)
            if DevEnv["BINGSU_PAUSE"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { openPause() } }
            // 디버그: BINGSU_LAYOUT=1 이면 3초 뒤 배치 편집기를 연다
            if DevEnv["BINGSU_LAYOUT"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { editLayout() } }
            thermometer.onSample = { [weak recorder] t in
                recorder?.ingest(fps: t.fps, p95: t.frameP95ms, stutters: t.lastStutters, memoryMB: t.memoryMB, thermal: t.thermal)
            }
            recorder.onBenchmark = { b in
                showToast("이 기기 권장 설정: \(b.quality.label) · 평균 \(Int(b.avgFps.rounded()))fps")
            }
            recorder.setActive(visible)
            // iCloud 에서 다른 기기 저장을 내려받아 열었으면 한 번 알린다
            if let t = Igloo.shared.takeToast(dish.id) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showToast(t) } }
            // 디버그: BINGSU_FAKE_HEAT=<초> 면 그만큼 뒤에 열 상태 serious, 두 배 뒤에 nominal 을 흉내 낸다 (자동 프레임 제한 검증용)
            if let s = DevEnv["BINGSU_FAKE_HEAT"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + s) { coolDown(.serious) }
                DispatchQueue.main.asyncAfter(deadline: .now() + s * 2) { coolDown(.nominal) }
            }
            // 디버그: BINGSU_CLOSE_AFTER=<초> 면 그만큼 뒤에 "게임 종료" (동기화 업로드 검증용)
            if let s = DevEnv["BINGSU_CLOSE_AFTER"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + s) { NSLog("[Bowl] debug close"); flush(); onClose() }
            }
        }
        .onDisappear {
            recorder.setActive(false)
            // 게임 종료(또는 다른 게임으로 바꿈): 마지막 스냅샷이 파일에 닿은 뒤 iCloud 로 올린다
            packSaveFiles()
            Igloo.shared.afterPlay(dish, stillRunning: false)
        }
        .onReceive(thermometer.$thermal) { t in
            recorder.thermalChanged(t)
            coolDown(t)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { n in
            controllerConnected = Self.realGamepadConnected()
            if controllerConnected { spoon.releaseAll() }
            let c = n.object as? GCController
            let kind = c?.extendedGamepad != nil ? "게임패드" : "확장 프로필 없음"
            showToast("컨트롤러 연결됨 · \(c?.vendorName ?? "?") (\(kind))")
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            controllerConnected = Self.realGamepadConnected()
            showToast("컨트롤러 연결 해제")
        }
        .onChange(of: watchConnected) { _, on in
            if on { spoon.releaseAll(); if visible { showToast("애플워치 연결됨 · 가상 패드 숨김") } }
        }
        .onChange(of: tableConnected) { _, on in
            if on { spoon.releaseAll(); if visible { showToast("iPhone 컨트롤러 연결됨 · 가상 패드 숨김") } }
        }
    }

    /// 눈송이 버튼(28pt)+여백이 들어가는 띠 폭. 게임은 항상 이 바깥에 그려진다.
    static let chrome: CGFloat = 48
    /// 게임 화면과 기기 가장자리 사이 여백, 둥근 모서리
    static let margin: CGFloat = 0
    static let corner: CGFloat = 0
    /// 워치 앱이 전면이고(닿음) 설정이 켜져 있으면 워치를 컨트롤러로 본다 → 가상 패드를 숨긴다 (실기기 피드백 2026-11-09)
    private var watchConnected: Bool { watchEnabled && watch.reachable && watch.watchAppInstalled }
    /// iPad 에 iPhone 이 컨트롤러로 붙어 있으면 (Spoon/TableSpoon.swift)
    private var tableConnected: Bool { tableEnabled && table.connected }
    private var anyController: Bool { controllerConnected || watchConnected || tableConnected }
    private var padShown: Bool { showSpoon && (!anyController || padForced) }

    private var padDebugText: String {
        let names = spoon.pressed.sorted { $0.rawValue < $1.rawValue }.map { $0.glyph }.joined(separator: " ")
        let l = spoon.leftStick.vector, r = spoon.rightStick.vector
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil && !$0.isSnapshot }.count
        return String(format: "pad:%d  [%@]  L(%.2f,%.2f) R(%.2f,%.2f)  %@", pads, names, l.dx, l.dy, r.dx, r.dy,
                      spoon.cutlery.transport == .gamepad ? "gamepad" : "keyboard")
    }

    /// 열 상태에 따라 프레임 제한을 바꾼다. 자동이고 처음부터 제한이 없던 게임만:
    /// serious 이상이면 30 으로, nominal 로 식으면 원래대로 (fair 에서는 그대로 둬 오르내림 반복을 막음).
    private func coolDown(_ t: ProcessInfo.ThermalState) {
        thermometer.fpsTarget = Double(currentFpsCap ?? 60)
        guard autoFps, baseFpsCap == nil else { return }
        if !heatCapped, t.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            heatCapped = true
            applyFpsCap(30)
            NSLog("[Bowl] fps heat cap 30 (thermal=\(t.rawValue))")
            showToast("기기가 뜨거워져 초당 30프레임으로 낮췄어요")
        } else if heatCapped, t == .nominal {
            heatCapped = false
            applyFpsCap(nil)
            NSLog("[Bowl] fps heat cap off")
            showToast("기기가 식어서 원래 프레임으로 돌렸어요")
        }
    }

    private var currentFpsCap: Int? { heatCapped ? 30 : baseFpsCap }

    private func applyFpsCap(_ cap: Int?) {
        recorder.fpsCap = cap
        thermometer.fpsTarget = Double(cap ?? 60)
        webView?.evaluateJavaScript("window.__bingsu && __bingsu.setFpsCap && __bingsu.setFpsCap(\(cap ?? 0))", completionHandler: nil)
    }

    // MARK: 일시정지 화면

    private var pauseBoard: some View {
        PauseBoard(
            dish: dish, thermometer: thermometer, pad: padPrefs,
            padFollowsGlobal: prefsStore.prefs(for: dish.id).pad == nil,
            setPad: setPadHere, applyToAllGames: applyPadToAll,
            padShown: Binding(get: { padShown }, set: { on in
                if on { showSpoon = true; padForced = anyController } else { showSpoon = false; spoon.releaseAll() }
            }),
            controllerNames: LongSpoon.connectedNames(),
            fpsLimit: Binding(get: { prefsStore.prefs(for: dish.id).fpsLimit }, set: setFpsLimit),
            quality: Binding(get: { prefsStore.prefs(for: dish.id).quality }, set: { q in prefsStore.update(dish.id) { $0.quality = q } }),
            musicRate: dish.knownWeb == .pokerogue ? Binding(get: { prefsStore.prefs(for: dish.id).musicRate }, set: setMusicRate) : nil,
            runningQuality: quality, showHUD: $showHUD, lastBackup: lastBackup,
            onResume: { closePause() },
            onHome: { closePause(resume: false); flush(); spoon.releaseAll(); onHome(); Igloo.shared.afterPlay(dish, stillRunning: true) },
            onClose: { closePause(resume: false); flush(); onClose() },
            onBackup: backup, onMoreSettings: { showSettings = true },
            onEditLayout: editLayout,
            focus: $pauseFocus)
    }

    /// 일시정지: 게임을 멈추고 패드 입력을 놓은 뒤 화면을 연다. 컨트롤러 입력은 화면 조작으로 돌린다.
    private func openPause() {
        guard !showMenu else { return }
        spoon.releaseAll()
        setWebAudioHeld(true)
        lastBackup = dish.isRemote ? nil : freezer.backups().first?.date
        pauseFocus = anyController ? .resume : nil
        longSpoon?.menuInput = { b in pauseInput(b) }
        teaSpoon?.menuInput = { b in pauseInput(b) }
        TeaSpoonLink.shared.setContext(game: dish.title, state: .paused)
        withAnimation(.easeOut(duration: 0.22)) { showMenu = true }
    }

    /// 일시정지 화면을 닫고(게임은 멈춘 채) 배치 편집기를 연다. 닫으면 일시정지 화면으로 돌아온다
    private func editLayout() {
        closePause(resume: false)
        spoon.releaseAll()
        showEditor = true
    }

    private func closePause(resume: Bool = true) {
        longSpoon?.menuInput = nil
        teaSpoon?.menuInput = nil
        if resume { TeaSpoonLink.shared.setContext(game: dish.title, state: .playing) }
        withAnimation(.easeOut(duration: 0.18)) { showMenu = false }
        if resume { setWebAudioHeld(false) }
    }

    /// 일시정지 화면에서 바꾼 패드 값은 이 게임에만 저장한다 (9.3)
    private func setPadHere(_ p: PadPrefs) {
        prefsStore.update(dish.id) { $0.pad = p }
    }

    /// "모든 게임에 적용": 지금 값을 전역 설정으로 쓰고 이 게임은 전역을 따르게 한다
    private func applyPadToAll() {
        PadPrefs.setGlobal(padPrefs)
        prefsStore.update(dish.id) { $0.pad = nil }
        showToast("모든 게임에 적용했어요")
    }

    /// 배경음악 음질: 저장하고 지금 페이지에도 알린다 (새로 푸는 곡부터)
    private func setMusicRate(_ v: MusicRate?) {
        prefsStore.update(dish.id) { $0.musicRate = v }
        webView?.evaluateJavaScript("window.__bingsuMusicRate && __bingsuMusicRate(\((v ?? .default).rawValue))", completionHandler: nil)
    }

    private func setFpsLimit(_ v: FpsLimit?) {
        prefsStore.update(dish.id) { $0.fpsLimit = v }
        baseFpsCap = prefsStore.prefs(for: dish.id).baseFpsCap(for: dish)
        autoFps = v == nil
        heatCapped = false
        applyFpsCap(baseFpsCap)
        coolDown(thermometer.thermal)
    }

    /// 일시정지 화면의 컨트롤러 조작: 위·아래 초점 이동, 왼·오른쪽 값 바꾸기, A 고르기, B·메뉴·홈 계속하기
    private func pauseInput(_ b: PadButton) {
        let items = pauseItems
        func step(_ d: Int) {
            guard let f = pauseFocus, let i = items.firstIndex(of: f) else { pauseFocus = items.first; return }
            let n = min(items.count - 1, max(0, i + d))
            if n != i { pauseFocus = items[n]; Rumble.shared.tap(intensity: 0.15) }
        }
        func nudge(_ v: Double, _ d: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, v + d)) }
        switch b {
        case .b, .menu, .home: closePause()
        case .up: step(-1)
        case .down: step(1)
        case .left, .right:
            let d: Double = b == .right ? 1 : -1
            var p = padPrefs
            switch pauseFocus {
            case .kind(let k):
                let all = PadKind.allCases, i = all.firstIndex(of: k) ?? 0
                let n = all[min(all.count - 1, max(0, i + Int(d)))]
                pauseFocus = .kind(n)
            case .size: p.scale = nudge(p.scale, 0.05 * d, 0.8...1.3); setPadHere(p)
            case .opacity: p.opacity = nudge(p.opacity, 0.05 * d, 0.25...0.9); setPadHere(p)
            case .volume: BingsuApp.setGameVolume(BingsuApp.gameVolume + 0.05 * d)
            case .rumbleStrength:
                let v = UserDefaults.standard.object(forKey: Rumble.strengthKey) == nil ? 0.7 : UserDefaults.standard.double(forKey: Rumble.strengthKey)
                UserDefaults.standard.set(nudge(v, 0.1 * d, 0.1...1), forKey: Rumble.strengthKey)
            case .fps:
                let opts: [FpsLimit?] = [nil, .fps30, .fps60]
                let i = opts.firstIndex(of: prefsStore.prefs(for: dish.id).fpsLimit) ?? 0
                setFpsLimit(opts[min(opts.count - 1, max(0, i + Int(d)))])
            case .musicRate:
                let all = MusicRate.allCases, cur = prefsStore.prefs(for: dish.id).musicRate ?? .default
                let i = all.firstIndex(of: cur) ?? 0
                setMusicRate(all[min(all.count - 1, max(0, i + Int(d)))])
            case .quality:
                let opts: [Quality?] = [nil, .high, .medium, .low]
                let i = opts.firstIndex(of: prefsStore.prefs(for: dish.id).quality) ?? 0
                let q = opts[min(opts.count - 1, max(0, i + Int(d)))]
                prefsStore.update(dish.id) { $0.quality = q }
            default: step(Int(d))
            }
        case .a:
            var p = padPrefs
            switch pauseFocus {
            case .resume?: closePause()
            case .home?: closePause(resume: false); flush(); spoon.releaseAll(); onHome(); Igloo.shared.afterPlay(dish, stillRunning: true)
            case .close?: closePause(resume: false); flush(); onClose()
            case .kind(let k)?: p.kind = k; setPadHere(p)
            case .editLayout?: editLayout()
            case .hidePad?: if padShown { showSpoon = false } else { showSpoon = true; padForced = anyController }
            case .labels?: p.showLabels.toggle(); setPadHere(p)
            case .floating?: p.floatingStick.toggle(); setPadHere(p)
            case .leftHand?: p.leftHanded.toggle(); setPadHere(p)
            case .applyAll?: applyPadToAll()
            case .mixAudio?: BingsuApp.setPlayInSilent(!BingsuApp.playInSilent(for: dish.id), for: dish.id)
            case .rumble?: UserDefaults.standard.set(!Rumble.shared.enabled, forKey: Rumble.key)
            case .btSafe?: UserDefaults.standard.set(!Rumble.shared.btSafe, forKey: Rumble.btSafeKey)
            case .hud?: showHUD.toggle()
            case .backup?: backup()
            case .more?: showSettings = true
            case nil: pauseFocus = items.first
            default: break
            }
        default: break
        }
    }

    /// 일시정지 화면에 보이는 순서대로 (PauseBoard 와 같은 조건)
    private var pauseItems: [PauseItem] {
        let p = padPrefs
        var out: [PauseItem] = [.resume, .home, .close] + PadKind.allCases.map { .kind($0) } + [.editLayout] + (p.kind == .oneHand ? [.leftHand] : []) + [.size, .opacity, .hidePad, .labels]
        if p.providesStick() { out.append(.floating) }
        if prefsStore.prefs(for: dish.id).pad != nil { out.append(.applyAll) }
        out += [.volume] + (dish.knownWeb == .pokerogue ? [.musicRate] : []) + [.mixAudio, .rumble]
        if Rumble.shared.enabled { out += [.rumbleStrength, .btSafe] }
        out += [.fps, .quality, .hud]
        if !dish.isRemote { out.append(.backup) }
        out.append(.more)
        return out
    }

    private func showToast(_ text: String) {
        NSLog("[Bowl] toast \(text)")
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { if toast == text { toast = nil } } }
    }

    @ViewBuilder private var menuButton: some View {
        let btn = Button { openPause() } label: {
            SnowOrb(size: 32, skin: SkinShelf.skin(for: padPrefs))
                .padding(8)   // 터치 영역
        }
        .accessibilityLabel("일시정지")
        switch menuButtonPlace {
        case .topRight:
            VStack { HStack { Spacer(); btn }; Spacer() }.padding(Self.cornerInset()).ignoresSafeArea()
        case .topLeft:
            VStack { HStack { btn; Spacer() }; Spacer() }.padding(Self.cornerInset()).ignoresSafeArea()
        case .pad:
            GeometryReader { geo in
                let ins = geo.safeAreaInsets
                let full = CGSize(width: geo.size.width + ins.leading + ins.trailing, height: geo.size.height + ins.top + ins.bottom)
                let l = SpoonLayout.make(prefs: padPrefs, size: full, safe: (ins.top, ins.leading, ins.bottom, ins.trailing))
                if padShown, let c = l.betweenViewMenu {
                    // 화면 아래로 벗어나지 않게
                    btn.position(x: c.x - ins.leading, y: min(c.y - ins.top, geo.size.height - 22))
                } else {
                    VStack { HStack { Spacer(); btn }; Spacer() }.padding(Self.cornerInset()).ignoresSafeArea()
                }
            }
        }
    }

    /// 게임 웹뷰의 자리 (geo 는 안전 영역을 무시한 전체 화면 좌표).
    /// 고정 비율(16:9) 게임: 세로는 눈송이 줄 아래 ~ 패드 윗줄 사이, 패드 쪽으로 치우치게, 가로는 높이를 채운 16:9 가운데.
    /// 그 밖의 웹 게임은 스스로 화면에 맞추므로 전체화면.
    private func gameRect(_ geo: GeometryProxy) -> CGRect {
        let W = geo.size.width, H = geo.size.height   // ignoresSafeArea → 화면 전체
        let fixedAspect = dish.recipe == .electron || dish.knownWeb == .pokerogue
        guard fixedAspect else { return CGRect(x: 0, y: 0, width: W, height: H) }
        let ins = Self.windowInsets()
        if H > W {
            return Self.portraitRect(W: W, H: H, top: ins.top, padTop: padLayout(full: geo.size, ins: ins)?.topEdge,
                                     orbInPad: menuButtonPlace == .pad && padShown, padShown: padShown)
        } else {
            return Self.landscapeRect(W: W, H: H, padShown: padShown)
        }
    }

    /// 세로 화면의 16:9 게임 자리 (배치 편집기의 자리 표시도 같은 계산). `padTop` 은 패드 맨 위 요소의 윗변
    static func portraitRect(W: CGFloat, H: CGFloat, top: CGFloat, padTop: CGFloat?, orbInPad: Bool, padShown: Bool) -> CGRect {
        let gameW = W - margin * 2
        let gameH = gameW * 9 / 16
        let padTop = padTop.map { $0 - 12 } ?? H
        // 눈송이 줄과 패드 윗줄 사이 남는 세로 공간에서 패드 쪽으로 치우치게(위 3 : 아래 1). 눈송이가 패드 안에 있으면 그 줄은 비워 두지 않는다
        let band = orbInPad ? 8 : chrome
        let slack = max(0, padTop - top - band - gameH)
        // 패드가 없으면(컨트롤러 연결 등) 창의 위아래 가운데. 눈송이 줄은 가리지 않는다
        let y = padShown ? top + band + slack * 0.75 : max(top + band, (H - gameH) / 2)
        return CGRect(x: margin, y: y, width: gameW, height: gameH)
    }

    /// 가로 화면의 16:9 게임 자리: 높이를 채우고, 양옆 여백이 눈송이 줄보다 좁으면 위에 눈송이 줄을 비워 둔다.
    /// 패드가 없으면(컨트롤러 연결 등) 눈송이 줄을 가리지 않는 한 창의 위아래 가운데에 둔다
    static func landscapeRect(W: CGFloat, H: CGFloat, padShown: Bool = true) -> CGRect {
        let innerH = H - margin * 2
        let fullW = min(W - margin * 2, innerH * 16 / 9)
        let sideBand = (W - fullW) / 2
        let gameH = sideBand >= chrome ? fullW * 9 / 16 : min(innerH - chrome, (W - margin * 2) * 9 / 16)
        let gameW = gameH * 16 / 9
        let cy = sideBand >= chrome ? H / 2 : chrome + (H - chrome) / 2
        let y = padShown || sideBand >= chrome ? cy - gameH / 2 : max(chrome, (H - gameH) / 2)
        return CGRect(x: (W - gameW) / 2, y: y, width: gameW, height: gameH)
    }

    /// 웹뷰가 페이지에 알릴 크기. 기본 게임(Bingsu)은 세로에서도 가로 화면과 같은 크기로 그려 똑같은 모습을 16:9 자리에 맞게 줄인다
    /// (2026-10-31 사용자 요청: 세로도 가로와 똑같이). 그 밖의 게임은 자리 크기 그대로
    private func pageSize(_ size: CGSize, rect r: CGRect) -> CGSize {
        guard MenuBoardStore.isBuiltIn(dish), size.height > size.width else { return r.size }
        let land = Self.landscapeRect(W: size.height, H: size.width).size
        return land.width > r.width ? land : r.size
    }

    /// 게임 소리(AudioContext)와 무음 모드용 무음 <audio> 를 함께 멈추거나 다시 켠다
    private func setWebAudioHeld(_ held: Bool) {
        webView?.evaluateJavaScript("window.__bingsu && __bingsu.\(held ? "pause" : "resume")(); window.__bingsuSilentHold && __bingsuSilentHold(\(held))",
                                    completionHandler: nil)
    }

    /// 돌아온 뒤 웹뷰 높이를 잠깐 1pt 줄였다 되돌리는 값.
    /// iPad 는 백그라운드 스냅샷 때 웹뷰 크기를 여러 번 바꾸는데, 돌아와서 resize 이벤트만 보내면 WebKit 이 예전 뷰포트를
    /// 그대로 알려 줘 게임이 작게 남는 일이 있다(2026-10-31 iPad Air). 실제로 크기를 바꿔 WebKit 이 뷰포트를 새로 계산하게 한다
    @State private var refitNudge: CGFloat = 0
    private func nudgeWebViewSize() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            refitNudge = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { refitNudge = 0 }
        }
    }

    /// 구석 눈송이를 화면 모서리에서 띄우는 거리. 둥근 화면(홈 버튼 없는 기기)은 모서리 곡선에 눈송이 일부가 잘려서
    /// 곡선 안쪽까지 들여 놓는다 (2026-10-31 아이폰 실기기, 컨트롤러 연결 시 오른쪽 위)
    static func cornerInset() -> CGFloat { windowInsets().bottom > 0 ? 10 : 0 }

    /// 창의 실제 안전 영역 (ignoresSafeArea 한 GeometryReader 에서는 0 으로 나오므로 창에서 읽는다)
    private static func windowInsets() -> UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets ?? scenes.first?.windows.first?.safeAreaInsets ?? .zero
    }

    /// 지금 보이는 가상 패드 배치 (화면 전체 좌표). 패드가 숨겨져 있으면 nil.
    private func padLayout(full: CGSize, ins: UIEdgeInsets) -> SpoonLayout? {
        guard padShown else { return nil }
        return SpoonLayout.make(prefs: padPrefs, size: full, safe: (ins.top, ins.left, ins.bottom, ins.right))
    }

    /// 이번 실행에서 웹 프로세스가 죽어 다시 불러온 횟수
    @State private var crashes = 0
    /// 게임이 안 보일 때 생긴 일은 돌아왔을 때 알린다
    @State private var toastOnReturn: String?
    private func showReturnToast() {
        guard visible, scenePhase == .active, let t = toastOnReturn else { return }
        toastOnReturn = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showToast(t) }
    }

    /// 게임이 처음부터 다시 떴다: 기록하고, 메모리 때문이면 알린다 (반복되면 화질 낮음 권장)
    private func restarted(_ kind: PerfRestart.Kind) {
        let hidden = !visible || scenePhase != .active
        recorder.noteRestart(kind, memoryMB: thermometer.memoryMB, thermal: thermometer.thermal, background: hidden)
        guard kind == .crash else { return }
        crashes += 1
        if hidden { toastOnReturn = "안 보이는 동안 iOS가 게임을 닫아서 다시 불러왔어요"; return }
        // 포켓로그는 캔버스가 1920×1080 고정이라 화질 '낮음'(devicePixelRatio)으로 메모리가 줄지 않는다
        let qualityHelps = dish.knownWeb != .pokerogue
        if crashes >= 2 && qualityHelps && quality != .low {
            showToast("메모리가 부족해 또 다시 불러왔어요 · 이 게임 설정 › 성능에서 화질을 '낮음'으로 바꿔 보세요")
        } else if crashes >= 2 {
            showToast("메모리가 부족해 또 다시 불러왔어요 · 다른 앱을 닫고 기기를 식히면 덜 생겨요")
        } else {
            showToast("기기 메모리가 부족해 게임을 다시 불러왔어요")
        }
    }

    private func flush() {
        webView?.evaluateJavaScript("window.__bingsu && __bingsu.flush()", completionHandler: nil)
        packSaveFiles()
    }

    /// MV·MZ 는 게임이 저장 데이터 폴더에 파일로 바로 쓴다(동기 쓰기라 이미 디스크에 있다) → save.json 으로 묶어
    /// 백업·iCloud 가 XP 와 같은 길을 타게 한다. 게임이 켜져 있으니 파일은 건드리지 않고 묶기만 한다
    private func packSaveFiles() {
        guard dish.recipe == .rpgMakerMV else { return }
        IceTray.sync(dish, allowUnpack: false)
    }

    /// 지금 상태를 먼저 파일로 보낸 뒤(메시지가 비동기라 잠깐 기다림) 복사본을 만든다
    private func backup() {
        flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let none = dish.recipe == .rpgMakerMV ? "아직 게임 안에서 저장한 데이터가 없어요" : "아직 저장된 데이터가 없어요"
            showToast(freezer.freeze() != nil ? "백업했어요" : none)
            lastBackup = freezer.backups().first?.date
        }
    }
}

struct ThermometerHUD: View {
    @ObservedObject var thermometer: Thermometer

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(thermometer.chill.color)).frame(width: 10, height: 10)
            Text(thermometer.chill.rawValue).bold()
            Text(String(format: "%.0f fps", thermometer.fps)).monospacedDigit()
            Text(String(format: "p95 %.0fms", thermometer.frameP95ms)).monospacedDigit().foregroundStyle(.secondary)
            Text(String(format: "%.0f MB", thermometer.memoryMB)).monospacedDigit().foregroundStyle(.secondary)
            if thermometer.lowPower { Image(systemName: "bolt.slash.fill").foregroundStyle(.yellow) }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
    }
}

/// 소리 문제 진단 HUD (설정 › 게임 중, 기본 끔): 게임 오디오 상태·최근 디코딩·마지막 진동·출력 종류를 한 줄로.
/// 소리가 깨지는 순간 어느 값이 같이 움직이는지 보려는 용도. 기기·이어폰 이름 같은 식별 정보는 넣지 않는다.
struct AudioDiagHUD: View {
    static let key = "bingsu.audioDiag"
    @ObservedObject var thermometer: Thermometer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            VStack(alignment: .leading, spacing: 2) {
                Text(audioLine)
                Text(hapticLine(now: ctx.date))
            }
            .font(.caption2.monospaced())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(.white)
        }
    }

    private var audioLine: String {
        let out = Rumble.bluetoothAudio ? "블루투스" : "기기·유선"
        guard let a = thermometer.audio else { return "소리: 컨텍스트 없음 · 출력 \(out)" }
        var s = String(format: "소리 %.0fHz %@ 지연 %.0fms", a.sampleRate, a.state, a.latencyMs)
        if let t = a.clock { s += String(format: " 시계 %.1f초", t) }
        if let m = a.decodeMs, let ago = a.decodeAgoSec { s += String(format: " · 디코딩 %.0fms(%.0f초 전)", m, ago) }
        return s + " · 출력 \(out)"
    }

    @MainActor private func hapticLine(now: Date) -> String {
        let r = Rumble.shared
        guard r.enabled else { return "진동 꺼짐" }
        let mode = r.btSafe && Rumble.bluetoothAudio ? " · 블루투스 보호 중" : ""
        guard let last = r.lastFire else { return "진동: 아직 없음" + mode }
        return String(format: "진동 %.1f초 전 · 최근 1초 %d회", now.timeIntervalSince(last), r.firesPerSecond) + mode
    }
}
