import SwiftUI
import UIKit
import GameController

/// RPG Maker XP·VX·VX Ace 게임 화면: 엔진(SDL) 화면 + 가상 패드 + 눈송이(일시정지) 화면.
/// 일시정지 화면은 웹 게임과 같은 `PauseBoard` (초당 프레임·화질·소리 다시 켜기는 엔진이 정해서 뺀다).
/// 웹 게임 화면(`BowlContainerView`)과 같은 자리에 같은 인자로 들어간다(MenuBoardView).
struct BrassBowlContainerView: View {
    let dish: Dish
    /// false 면 홈(게임 목록) 뒤에 숨어 멈춘 상태. 엔진은 살아 있다
    var visible = true
    var onHome: () -> Void = {}
    let onClose: () -> Void

    @ObservedObject private var engine = BrassBowlEngine.shared
    @StateObject private var thermometer = Thermometer()
    @StateObject private var spoon = SpoonController()
    @StateObject private var recorder: PerfRecorder
    @State private var longSpoon: LongSpoon?
    @State private var teaSpoon: TeaSpoon?   // 애플워치 (Spoon/TeaSpoon.swift)
    @State private var toast: String?
    @State private var toastTone: ToastTone = .info
    @State private var startError: String?
    @State private var showMenu = false
    @State private var pauseFocus: PauseItem?
    /// 저장 (빌드 49·50): 이번 실행에서 지원 안 한다고 답했는지, 저장·불러오기 중인지
    @State private var scoopUnsupported = false
    @State private var scoopRunning = false
    /// 상태 저장 목록 (여러 칸)
    @StateObject private var stateList: ScoopList
    @State private var showStates = false
    /// 일시정지 화면 저장 묶음: 가장 최근 칸과 칸 수
    @State private var latestSave: Scoop.Entry?
    /// iPhone Duo 경첩 (반 접기면 게임을 접히는 선 위로)
    @ObservedObject private var hinge = HingeStore.shared
    @State private var saveCount = 0
    /// 자동 저장 (빌드 49): 마지막 시도 시각, 저장하는 동안(나가는 중에도 엔진을 잠깐 더 돌림)
    @State private var lastAutoTry = Date()
    @State private var autoSaving = false
    @State private var showSettings = false
    /// 카메라 피해서 가운데 (iPhone Duo 바깥 화면, GameFrame.avoidCamera)
    @AppStorage(GameFrame.avoidCameraKey) private var avoidCamera = false
    /// 배치 편집 (일시정지 화면 › 배치 편집). 엔진은 멈춘 채 그 위에 편집기를 띄운다
    @State private var showEditor = false
    @State private var confirmQuit = false
    /// 진단 정보 보내기 (ReceiptSlipView)
    @State private var receipt: ReceiptRequest?
    /// RTP 가 없는 게임을 처음 열 때 한 번 안내한다 (DishPrefs.rtpNoticeShown)
    @State private var rtpNotice = false
    @State private var fpsTimer: Timer?
    @State private var controllerConnected = BowlContainerView.realGamepadConnected()
    @ObservedObject private var watch = TeaSpoonLink.shared
    @AppStorage(TeaSpoonLink.enabledKey) private var watchEnabled = true
    @ObservedObject private var table = TableSpoonLink.shared
    @AppStorage(TableSpoonLink.enabledKey) private var tableEnabled = true
    @State private var showSpoon = true
    /// 게임 키보드 (Spoon/GameKeyboard.swift). 켜면 패드 대신 자판이 아래에 뜬다
    @State private var showKeyboard = false
    /// 게임의 키보드 입력 화면(두벌식 이름 입력)이 열려 있으면 그 한/영 상태(true 한글). 닫혀 있으면 nil
    @State private var entryKorean: Bool? = nil
    /// 그 화면 때문에 키보드를 저절로 올렸는지 (닫히면 다시 내린다)
    @State private var keyboardAuto = false
    @State private var padForced = DevEnv["BINGSU_FORCE_PAD"] == "1"
    @AppStorage("bingsu.showPerformance") private var showHUD = false
    @AppStorage("bingsu.menuButton") private var menuButtonRaw = MenuButtonPlace.pad.rawValue
    @ObservedObject private var prefsStore = DishPrefsStore.shared
    // 전역 패드 설정이 바뀌면 다시 그리도록 관찰
    @AppStorage("spoon.kind") private var gKind = PadKind.simple.rawValue
    @AppStorage("spoon.scale") private var gScale = 1.0
    @AppStorage("spoon.opacity") private var gOpacity = 0.55
    @AppStorage("spoon.floatingStick") private var gFloating = true
    @AppStorage("spoon.showLabels") private var gLabels = false
    @AppStorage("spoon.haptics") private var gHaptics = true
    @AppStorage("spoon.leftHanded") private var gLeftHanded = false
    @AppStorage(PadPrefs.skinKey) private var gSkin: String?
    @AppStorage(PadPrefs.layoutsKey) private var gLayouts: Data?
    @Environment(\.scenePhase) private var scenePhase

    private var padPrefs: PadPrefs { prefsStore.effectivePad(for: dish.id) }
    /// 워치 앱이 전면이고(닿음) 설정이 켜져 있으면 워치를 컨트롤러로 본다 → 가상 패드를 숨긴다 (실기기 피드백 2026-11-09)
    /// 워치로 조작 중이면 연결로 본다: 처음 닿거나 입력이 온 뒤, 워치가 잠들어도 2분은 유지 (화면이 흔들리지 않게). isWatchAppInstalled 는 안 본다
    private var watchConnected: Bool { watchEnabled && watch.engaged }
    /// iPad 에 iPhone 이 컨트롤러로 붙어 있으면 (Spoon/TableSpoon.swift)
    private var tableConnected: Bool { tableEnabled && table.connected }
    private var anyController: Bool { controllerConnected || watchConnected || tableConnected }
    private var padShown: Bool { showSpoon && !showKeyboard && (!anyController || padForced) }
    /// 일시정지 화면이 떠도 키보드는 그 아래 그대로 둔다 (게임 화면이 오르내리지 않게)
    private var keyboardShown: Bool { showKeyboard && isPlaying && !showEditor }
    private var menuButtonPlace: MenuButtonPlace {
        if let e = DevEnv["BINGSU_MENU_BUTTON"], let p = MenuButtonPlace(rawValue: e) { return p }
        // 한손 배치는 설정과 상관없이 패드 구역 오른쪽 위에 고정 (2026-10-31 사용자 결정, 자리는 makeOneHand)
        if padPrefs.kind == .oneHand { return .pad }
        return MenuButtonPlace(rawValue: menuButtonRaw) ?? .pad
    }
    private var freezer: Freezer { Freezer(dish: dish) }
    /// 게임 화면 비율: 엔진이 알려 준 값(게임이 해상도를 바꾸면 따라감), 아직 모르면 판 기본값
    /// (XP 4:3 — 게임마다 512×384·640×480 등, VX·VX Ace 544×416)
    private var aspect: CGFloat {
        engine.gameAspect ?? (BrassBowlEngine.rgss(for: dish) == .xp ? 4.0 / 3.0 : 544.0 / 416.0)
    }

    init(dish: Dish, visible: Bool = true, onHome: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.dish = dish; self.visible = visible; self.onHome = onHome; self.onClose = onClose
        _recorder = StateObject(wrappedValue: PerfRecorder(dishID: dish.id, title: dish.title, quality: .high))
        _stateList = StateObject(wrappedValue: ScoopList(dish: dish))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                let r = gameRect(geo.size)
                BrassBowlHost(onEmbed: { applyViewport(geo.size) })
                    .ignoresSafeArea()
                    .onAppear { applyViewport(geo.size) }
                    .onChange(of: geo.size) { _, s in applyViewport(s) }
                    // 다른 앱에서 돌아오면 iOS 가 스냅샷 때 바꾼 엔진 창 크기를 되돌리지만 geo.size 는 그대로라
                    // 다시 알려 주지 않으면 게임 화면이 작은 채 남는다(iPad). 자리 잡는 동안 몇 번 다시 알린다
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        for t in [0.1, 0.5, 1.2] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { applyViewport(geo.size) } }
                    }
                    .onChange(of: padShown) { _, _ in applyViewport(geo.size) }
                    .onChange(of: showKeyboard) { _, _ in applyViewport(geo.size) }
                    .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in pollEntrySignal() }
                    .onChange(of: engine.gameAspect) { _, _ in applyViewport(geo.size) }
                    .onChange(of: avoidCamera) { _, _ in applyViewport(geo.size) }
                    .onChange(of: hinge.pose) { _, _ in applyViewport(geo.size) }
                if avoidCamera, geo.size.width > geo.size.height, GameFrame.hasCameraStrip(GameFrame.windowInsets()), !keyboardShown {
                    CameraSideBands(game: r, screen: geo.size)
                }
                if isPlaying, let fold = hinge.pose.halfFoldLine(size: geo.size, insets: GameFrame.windowInsets()) {
                    HalfFoldPadBase(fold: fold, screen: geo.size, game: r)
                }
                if !isPlaying {
                    loadingCover.frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                }
            }
            .ignoresSafeArea()

            if padShown && isPlaying && !showEditor { SpoonOverlay(controller: spoon, prefs: padPrefs) }
            // 반 접기로 세워 두고 컨트롤러로 할 때: 아래 절반에 컨트롤러 상태·저장·불러오기·일시정지
            if !padShown && isPlaying && !showEditor && !keyboardShown {
                GeometryReader { geo in
                    if let fold = hinge.pose.halfFoldLine(size: geo.size, insets: GameFrame.windowInsets()) {
                        HalfFoldStandPanel(fold: fold, screen: geo.size, onSave: scoopShown ? saveNew : nil,
                                           onLoad: scoopShown ? openStates : nil, onPause: openPause)
                    }
                }
                .ignoresSafeArea()
            }
            if keyboardShown {
                GeometryReader { geo in
                    let ins = geo.safeAreaInsets
                    let W = geo.size.width + ins.leading + ins.trailing
                    let h = GameKeyboard.height(width: W, bottomInset: ins.bottom)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        GameKeyboard(send: { code, down in
                            guard let sc = BrassKeys.scancode(code) else { return }
                            if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[BrassBowl] keyboard \(code)=\(sc) \(down)") }
                            BrassBowlEngine.shared.key(sc, down: down)
                        }, onPad: { showKeyboard = false; keyboardAuto = false }, onMenu: { openPause() }, haptics: padPrefs.haptics,
                           startKorean: Self.prefersKorean(dish), gameKorean: entryKorean,
                           textMode: engine.textInputActive,
                           type: { op in
                               if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[BrassBowl] keyboard text \(op)") }
                               BrassBowlEngine.shared.feed(op)
                           })
                        .frame(width: W, height: h)
                    }
                    .frame(width: W, height: geo.size.height + ins.top + ins.bottom)
                }
                .ignoresSafeArea()
                .transition(.move(edge: .bottom))
            }
            // 워치·iPhone 컨트롤러 때문에 숨겨졌을 때 손으로 되돌리는 단추 (Spoon/PadRevealButton.swift)
            if isPlaying && !showEditor && (watchConnected || tableConnected) && !controllerConnected {
                if !padShown { PadRevealButton(mode: .reveal) { showSpoon = true; padForced = true } }
                else if padForced { PadRevealButton(mode: .hide) { padForced = false; spoon.releaseAll() } }
            }

            if showHUD {
                VStack {
                    HStack { ThermometerHUD(thermometer: thermometer); Spacer() }.padding(.horizontal, 12).padding(.top, 8)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            if let toast {
                VStack {
                    ToastBadge(text: toast, tone: toastTone).padding(.top, 10)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(5)
            }
            if case .ended(let id, let clean) = engine.phase, id == dish.id { endedCover(clean: clean) }
            // 게임 키보드에는 메뉴 키가 따로 있다 — 눈송이를 또 띄우지 않는다
            if !showMenu && !showEditor && !keyboardShown { menuButton }
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
        .alert("게임을 끝낼까요?", isPresented: $confirmQuit) {
            Button("끝내기", role: .destructive) { quit() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("게임 안에서 저장하지 않은 진행은 사라져요. 이 게임은 끝낸 뒤 빙수를 다시 열어야 다시 할 수 있어요.")
        }
        .sheet(isPresented: $showStates, onDismiss: refreshSaves) { ScoopListView(model: stateList) }
        .alert("RTP 가 필요해요", isPresented: $rtpNotice) {
            Button("그냥 열기") { rtpNoticeDone(); startEngine() }
            Button("목록으로", role: .cancel) { rtpNoticeDone(); onClose() }
        } message: {
            Text("이 게임은 공용 그림·소리 묶음(RTP · \(dish.rtp ?? ""))을 따로 써요. RTP 폴더를 zip 으로 묶어 게임 추가 › zip 파일 가져오기로 넣어 주세요. RTP 설치 파일(exe)은 넣을 수 없어요. 그냥 열면 그림이나 소리가 빠질 수 있어요.")
        }
        .alert("게임 오류", isPresented: Binding(get: { engine.errorMessage != nil }, set: { if !$0 { engine.dismissError() } })) {
            Button("확인") { engine.dismissError() }
        } message: {
            Text(engine.errorMessage ?? "")
        }
        .alert("열 수 없어요", isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("목록으로") { startError = nil; onClose() }
        } message: {
            Text(startError ?? "")
        }
        // 이름 입력처럼 게임이 글자를 기다릴 때: 게임 키보드를 글자 모드로 올린다 (빌드 42, 예전엔 iOS 글자 입력 창)
        .onChange(of: engine.textInputActive) { _, on in textInputChanged(on) }
        .onChange(of: keyboardShown) { _, on in lockPortraitForKeyboard(on) }
        // 게임 키보드·두벌식 이름 입력 화면에서는 하드웨어 키를 바꾸지 않는다 (키 설정, Spoon/HardKeys.swift)
        .onChange(of: keyboardShown || entryKorean != nil) { _, on in HardKeys.shared.textScreen = on }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in hardKeyboardChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in hardKeyboardChanged() }
        .sheet(isPresented: $showSettings) { DishSettingsView(dish: dish, onReceipt: openReceiptFromSettings) }
        .sheet(item: $receipt) { r in ReceiptSlipView(dish: dish, live: r.live, screenshot: r.screenshot) }
        .onChange(of: padPrefs.haptics) { _, on in spoon.hapticsEnabled = on }
        // 자동 저장 간격: 화면이 다시 그려져도 처음부터 세지 않게 화면 수명 동안 도는 작업으로 (보임·앱 상태가 바뀌면 새로)
        .task(id: "\(visible)|\(scenePhase)") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(30, Scoop.autoEvery / 2)))
                if visible, scenePhase == .active, !showMenu, !showStates, Date().timeIntervalSince(lastAutoTry) >= Scoop.autoEvery { autoSave("timer") }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // 앱을 떠나기 직전(아직 그릴 수 있을 때) 자동 저장. 백그라운드에선 엔진이 멈추므로 못 끝내면 돌아와서 끝난다
            if phase == .inactive, visible, !showMenu, Date().timeIntervalSince(lastAutoTry) > 60 { autoSave("leave") }
            if phase != .active { spoon.releaseAll() }
            if phase == .background {
                engine.pause()
                afterPlay(stillRunning: true)
            } else if phase == .active && visible && !showEditor {
                engine.resume()
            }
            recorder.setActive(phase == .active && visible)
        }
        .onChange(of: visible) { _, v in
            if !v && showMenu { closePause(resume: false) }
            longSpoon?.enabled = v
            recorder.setActive(v && scenePhase == .active)
            if v { engine.resume() } else if !autoSaving { engine.pause() }
        }
        .onChange(of: engine.phase) { _, p in
            if case .ended(let id, _) = p, id == dish.id { spoon.releaseAll() }   // 저장 묶기·올리기는 엔진이 끝날 때 BrassBowlEngine 이
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; start() }   // 게임 중 화면 안 꺼짐 (컨트롤러·워치로 하면 iPhone 을 안 건드린다)
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            HardKeyText.shared.stop()
            HardKeys.shared.detach(spoon: spoon)
            lockPortraitForKeyboard(false)
            fpsTimer?.invalidate()
            recorder.setActive(false)
            // 다른 게임을 열거나 "종료"로 이 화면이 사라짐: 엔진을 끝낸다 (끝나면 엔진이 저장 파일을 묶어 올림)
            if engine.runningDishID == dish.id { engine.terminate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            controllerConnected = BowlContainerView.realGamepadConnected()
            if controllerConnected { spoon.releaseAll() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            controllerConnected = BowlContainerView.realGamepadConnected()
        }
        .onChange(of: watchConnected) { _, on in
            if on { spoon.releaseAll(); if isPlaying { showToast("애플워치 연결됨 · 가상 패드 숨김") } }
        }
        // 손으로 꺼낸 패드도 워치 입력이 다시 오면 숨긴다 (2026-11-10 사용자 요청)
        .onChange(of: watch.lastInputAt) { _, _ in
            if padForced && watchConnected { padForced = false; spoon.releaseAll() }
        }
        .onChange(of: tableConnected) { _, on in
            if on { spoon.releaseAll(); if isPlaying { showToast("iPhone 컨트롤러 연결됨 · 가상 패드 숨김") } }
        }
    }

    private var isPlaying: Bool { engine.phase == .playing(dishID: dish.id) }

    private var loadingCover: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("게임을 여는 중…").font(.subheadline).foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func endedCover(clean: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: clean ? "checkmark.circle" : "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.white.opacity(0.85))
            Text(clean ? "게임이 끝났어요" : "게임이 멈췄어요").font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text("이 게임을 다시 하려면 앱 전환기에서 빙수를 위로 밀어 닫은 뒤 다시 열어 주세요. 저장한 데이터는 그대로 있어요.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("목록으로") { onClose() }.buttonStyle(.borderedProminent).tint(Palette.accent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }

    // MARK: 시작·끝

    private func start() {
        spoon.cutlery = CutlerySet.forDish(dish)
        if DevEnv["BINGSU_KEYBOARD"] == "1" { showKeyboard = true }   // 디버그: 게임 키보드를 띄운 채 시작
        spoon.hapticsEnabled = padPrefs.haptics
        spoon.keySink = { code, down in
            guard let sc = BrassKeys.scancode(code) else { return }
            if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[BrassBowl] key \(code)=\(sc) \(down)") }
            BrassBowlEngine.shared.key(sc, down: down)
        }
        HardKeys.shared.attach(dish: dish, spoon: spoon)   // 키 설정 (컨트롤러·하드웨어 키보드)
        if longSpoon == nil { longSpoon = LongSpoon(spoon: spoon) }
        longSpoon?.enabled = visible
        longSpoon?.onHomeButton = { if visible && !showMenu && !showEditor { openPause() } }
        if teaSpoon == nil { teaSpoon = TeaSpoon(spoon: spoon) }      // 애플워치 → 같은 경로로 입력
        teaSpoon?.enabled = visible
        teaSpoon?.onHomeButton = { if visible && !showMenu && !showEditor { openPause() } }
        TeaSpoonLink.shared.setContext(game: dish.title, state: visible ? .playing : .home)
        thermometer.fpsTarget = 60
        thermometer.onSample = { [weak recorder] t in
            recorder?.ingest(fps: t.fps, p95: t.frameP95ms, stutters: t.lastStutters, memoryMB: t.memoryMB, thermal: t.thermal)
        }
        recorder.setActive(visible)
        if let t = Igloo.shared.takeToast(dish.id) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showToast(t) } }
        guard engine.runningDishID != dish.id else { return }   // 이미 켜져 있음(화면만 다시 만들어짐)
        if dish.needsRTP, let rtp = dish.rtp, !RTPShelf.isInstalled(rtp), prefsStore.prefs(for: dish.id).rtpNoticeShown != true {
            rtpNotice = true
            return
        }
        startEngine()
    }

    private func rtpNoticeDone() {
        prefsStore.update(dish.id) { $0.rtpNoticeShown = true }
    }

    /// 엔진 켜기 (RTP 안내를 거친 뒤)
    private func startEngine() {
        // 예전 빌드가 게임 폴더에 남긴 저장(옛 Essentials Game.rxdata, XP Save1.rxdata)을 저장 데이터 폴더로 (2026-11-17)
        _ = Delivery.moveGameFolderSaves(dish)
        // iCloud·백업 되돌리기로 save.json 이 바뀌었으면 Game.rxdata 로 풀어 둔다 (게임이 켜지기 전)
        IceTray.sync(dish, allowUnpack: true)
        if let err = engine.start(.init(dish: dish, savesDir: freezer.directory)) {
            ReceiptDesk.shared.noteError(dishID: dish.id, kind: .start, message: err)
            startError = err
            return
        }
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                let fps = BrassBowlEngine.shared.averageFPS
                guard fps > 0 else { return }
                thermometer.ingest(fps: fps, p95: 1000 / max(fps, 1), stutters: 0)
            }
        }
        debugKeys()
        for (t, step) in Scoop.debugPlan() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { debugScoop(step) }
        }
        // 디버그: BINGSU_PAUSE=<초> 면 그 뒤 일시정지 화면을 연다 (시안 스크린샷용)
        if let t = DevEnv["BINGSU_PAUSE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { openPause() }
        }
        // 디버그: BINGSU_RECEIPT=<초> 면 그 뒤 일시정지 화면을 열고 진단 정보를 띄운다 (시뮬레이터 확인용)
        if let t = DevEnv["BINGSU_RECEIPT"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { openPause(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openReceipt() } }
        }
    }

    /// 디버그: BINGSU_KEYS="초:코드,..." 면 그 시각에 키를 짧게 누른다 (예: "12:Enter,15:KeyC"). 시뮬레이터 자동 확인용
    private func debugKeys() {
        // BINGSU_AUTOKEY="코드:간격초:횟수" 면 그 키를 계속 누른다(긴 대사 넘기기). 글자 입력 창·키보드 입력 화면이 뜨면 멈춤
        if let spec = DevEnv["BINGSU_AUTOKEY"] {
            let p = spec.split(separator: ":")
            if p.count == 3, let sc = BrassKeys.scancode(String(p[0])), let gap = Double(p[1]), let n = Int(p[2]) {
                for i in 0..<n {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12 + gap * Double(i)) {
                        let e = BrassBowlEngine.shared
                        guard !e.textInputActive, e.runningDishID != nil,
                              !FileManager.default.fileExists(atPath: BrassBowlEngine.entrySignalFile.path) else { return }
                        e.key(sc, down: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { e.key(sc, down: false) }
                    }
                }
            }
        }
        guard let spec = DevEnv["BINGSU_KEYS"] else { return }
        for pair in spec.split(separator: ",") {
            let p = pair.split(separator: ":")
            guard p.count == 2, let t = Double(p[0]), let sc = BrassKeys.scancode(String(p[1])) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                NSLog("[BrassBowl] debug key \(p[1])")
                BrassBowlEngine.shared.key(sc, down: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { BrassBowlEngine.shared.key(sc, down: false) }
            }
        }
    }

    private func goHome() {
        spoon.releaseAll()
        // 나갈 때 자동 저장: 홈으로 먼저 보내고, 엔진은 저장이 끝날 때까지(1초 안팎) 뒤에서 돌린 뒤 멈춘다
        if Scoop.autoOn, scoopShown, isPlaying, !scoopRunning, Date().timeIntervalSince(lastAutoTry) > 20 {
            engine.resume()
            autoSave("home") {
                if !visible { engine.pause() }
                afterPlay(stillRunning: true)
            }
            onHome()
            return
        }
        engine.pause()
        onHome()
        afterPlay(stillRunning: true)
    }

    /// 게임 종료: 엔진을 끝낸다. 끝나면 "빙수를 다시 열어 주세요" 화면이 뜬다(endedCover)
    private func quit() {
        closePause(resume: false)
        spoon.releaseAll()
        engine.terminate()
    }

    /// 게임이 쓴 저장 파일을 save.json 으로 묶고(Igloo 를 꺼 둬도 백업이 되게) iCloud 로 올린다
    private func afterPlay(stillRunning: Bool) {
        // 세이브 카드: 게임 안 Ruby 가 임시 폴더에 남긴 옆 정보·사진을 이 게임 자리로 (빌드 49)
        SaveCard.ingest(dish)
        IceTray.sync(dish, allowUnpack: !stillRunning)
        Igloo.shared.afterPlay(dish, stillRunning: stillRunning)
    }

    // MARK: 빠른 저장/불러오기 (빌드 49)

    private var scoopShown: Bool { Scoop.supports(dish) && !scoopUnsupported }

    /// 일시정지 화면을 닫고 게임을 다시 돌린 뒤, 맵 화면이 받아 갈 때 게임의 저장 코드로 저장하거나 불러온다.
    /// 저장하면 칸 사진으로 일시정지 때 엔진이 찍어 둔 화면(메뉴가 안 찍힌 게임 화면)을 남긴다
    private func quick(_ op: Scoop.Op, _ slot: Scoop.Slot = .quick) {
        guard isPlaying, !scoopRunning else { return }
        // 엔진 화면은 일시정지할 때 찍히므로, 일시정지 화면에서 저장할 때만 쓴다 (아니면 예전 화면일 수 있음)
        let photo = op == .save && showMenu ? engine.snapshotImage() : nil
        if showMenu { closePause() }
        scoopRunning = true
        Task {
            let o = await engine.scoop(op, slot, dish: dish)
            scoopRunning = false
            if o == .unsupported { scoopUnsupported = true }
            if o == .ok {
                if op == .save {
                    ScoopShelf.keep(photo, dish, slot)
                    IceTray.sync(dish, allowUnpack: false)
                    Igloo.shared.afterPlay(dish, stillRunning: true)
                }
            }
            refreshSaves()
            showToast(Scoop.message(o, op, slot), tone: o == .ok ? .ok : .fail)
        }
    }

    /// 자동 저장 칸에 조용히 저장 (알림 없음). 바쁘면(이벤트·메뉴 중) 30초 뒤 다시. 사진은 게임 안 Ruby 가 남기는 맵 화면
    private func autoSave(_ why: String, then: (() -> Void)? = nil) {
        guard Scoop.autoOn, scoopShown, isPlaying, !scoopRunning else { then?(); return }
        lastAutoTry = Date()
        scoopRunning = true
        autoSaving = true
        Task {
            let o = await engine.scoop(.save, .auto, dish: dish)
            scoopRunning = false
            autoSaving = false
            NSLog("[BrassBowl] auto save (\(why)) → \(o)")
            if o == .unsupported { scoopUnsupported = true }
            if o == .ok {
                IceTray.sync(dish, allowUnpack: false)
                Igloo.shared.afterPlay(dish, stillRunning: true)
                refreshSaves()
            } else if o == .busy || o == .timeout {
                lastAutoTry = Date().addingTimeInterval(30 - Scoop.autoEvery)
            }
            then?()
        }
    }

    /// 저장: 바로 비어 있는 새 칸에 (빌드 50). 칸이 다 찼으면 알리고 목록을 연다
    private func saveNew() {
        guard let slot = Scoop.freeState(dish) else {
            showToast("저장 칸이 다 찼어요. 불러오기에서 지우거나 덮어써 주세요", tone: .fail)
            return
        }
        quick(.save, slot)
    }

    private func refreshSaves() {
        let all = Scoop.entries(dish)
        latestSave = all.first
        saveCount = all.count
    }

    /// 상태 저장 목록 열기 (일시정지 화면 위 시트). 저장·불러오기는 시트와 일시정지를 닫고 `quick` 으로
    private func openStates() {
        stateList.reload()
        stateList.focus = nil
        stateList.controllerFocus = anyController
        stateList.onClose = { showStates = false }
        stateList.onSave = { slot in
            showStates = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { quick(.save, slot) }
        }
        stateList.onLoad = { slot in
            showStates = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { quick(.load, slot) }
        }
        showStates = true
    }

    /// 디버그 BINGSU_SCOOP (Scoop.debugPlan)
    private func debugScoop(_ step: Scoop.DebugStep) {
        switch step {
        case .run(let op, let slot): quick(op, slot)
        case .new:
            if let slot = Scoop.freeState(dish) { quick(.save, slot) }
            else { openPause(); openStates(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { stateList.saveNew() } }
        case .list: openPause(); openStates()
        case .fill: Scoop.debugFill(dish); refreshSaves(); NSLog("[Scoop] fill → \(saveCount)")
        }
    }

    /// 게임이 글자 요청을 켜면 게임 키보드를 저절로 올리고, 끄면 저절로 올린 것만 내린다
    private func textInputChanged(_ on: Bool) {
        if on {
            // 하드웨어 키보드가 있으면 화면 키보드 없이 그 키보드로 글자를 받는다
            if HardKeyText.connected { startHardText(); return }
            guard !showKeyboard else { return }
            spoon.releaseAll()
            keyboardAuto = true
            withAnimation(.easeOut(duration: 0.2)) { showKeyboard = true }
        } else {
            HardKeyText.shared.stop()
            if keyboardAuto, entryKorean == nil {
                keyboardAuto = false
                withAnimation(.easeOut(duration: 0.2)) { showKeyboard = false }
            }
        }
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
            runningQuality: .high, showHUD: $showHUD,
            onResume: { closePause() },
            onHome: { closePause(resume: false); goHome() },
            onClose: { confirmQuit = true },
            onMoreSettings: { showSettings = true },
            onSave: scoopShown ? saveNew : nil,
            onLoad: scoopShown ? openStates : nil,
            latestSave: latestSave,
            saveCount: saveCount,
            onEditLayout: editLayout,
            onKeyboard: openKeyboard,
            showsCameraOption: true,
            focus: $pauseFocus)
    }

    /// 진단 정보: 지금 화면·입력 상태와 일시정지 때 엔진이 찍어 둔 화면을 모아 미리보기를 연다
    /// 이 게임 설정 › 진단 정보: 설정 시트가 닫힌 뒤 지금 화면 상태를 담아 연다
    private func openReceiptFromSettings() {
        showSettings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openReceipt() }
    }

    private func openReceipt() {
        recorder.save()
        let live = ReceiptLive(
            gameFrame: engine.gameRect,
            input: ReceiptSlip.inputLines(padShown: padShown, padKind: padPrefs.kind, watch: watchConnected, table: tableConnected,
                                          gameKeyboard: showKeyboard),
            screenExtra: [ReceiptSlip.Line(key: "눈송이 단추", value: menuButtonPlace == .pad ? "패드 안" : "구석")])
        receipt = ReceiptRequest(live: live, screenshot: engine.snapshotImage())
    }

    /// 일시정지: 엔진을 멈추고 패드 입력을 놓은 뒤 화면을 연다. 컨트롤러 입력은 화면 조작으로 돌린다
    private func openPause() {
        guard !showMenu, isPlaying else { return }
        spoon.releaseAll()
        engine.pause()
        IceTray.sync(dish, allowUnpack: false)
        refreshSaves()
        pauseFocus = anyController ? .resume : nil
        longSpoon?.menuInput = { b in pauseInput(b) }
        teaSpoon?.menuInput = { b in pauseInput(b) }
        TeaSpoonLink.shared.setContext(game: dish.title, state: .paused)
        withAnimation(.easeOut(duration: 0.22)) { showMenu = true }
    }

    /// 일시정지 화면을 닫고 게임 키보드를 띄운다 (패드 자리)
    /// 게임이 키보드 입력 화면을 열고 닫는 것을 따라 키보드를 올리고 내린다 (BrassBowlEngine.entryScript 가 쓰는 신호 파일)
    private func pollEntrySignal() {
        guard isPlaying else { return }
        let v = try? String(contentsOf: BrassBowlEngine.entrySignalFile, encoding: .utf8)
        let k: Bool? = v.map { $0 != "en" }
        guard k != entryKorean else { return }
        let opened = entryKorean == nil
        entryKorean = k
        if k != nil, opened, !showKeyboard, !HardKeyText.connected {
            spoon.releaseAll()
            keyboardAuto = true
            withAnimation(.easeOut(duration: 0.2)) { showKeyboard = true }
        } else if k == nil, keyboardAuto, !engine.textInputActive {
            keyboardAuto = false
            withAnimation(.easeOut(duration: 0.2)) { showKeyboard = false }
        }
    }

    private func startHardText() {
        HardKeyText.shared.start(korean: entryKorean ?? Self.prefersKorean(dish)) { op in
            if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[BrassBowl] hardware text \(op)") }
            BrassBowlEngine.shared.feed(op)
        }
    }

    /// 글자 입력 중에 하드웨어 키보드를 꽂으면 저절로 올린 화면 키보드를 내리고, 빼면 다시 올린다
    private func hardKeyboardChanged() {
        guard engine.textInputActive else { return }
        if HardKeyText.connected {
            startHardText()
            if keyboardAuto { keyboardAuto = false; withAnimation(.easeOut(duration: 0.2)) { showKeyboard = false } }
        } else {
            HardKeyText.shared.stop()
            textInputChanged(true)
        }
    }

    /// iPhone 가로에서 게임 키보드를 열면 세로로 돌려 쓰고, 닫으면 원래대로 (iPad·iPhone Duo 안쪽 화면은 그대로 아래에)
    private func lockPortraitForKeyboard(_ on: Bool) {
        guard !on || SpoonLayout.currentIdiom == .phone else { return }   // 풀기는 늘 (접었다 편 뒤에도 풀리게)
        AppDelegate.lockOrientation(on ? .portrait : nil)
    }

    private func openKeyboard() {
        spoon.releaseAll()
        withAnimation(.easeOut(duration: 0.2)) { showKeyboard = true }
        closePause()
    }

    /// 한글 게임이면 자판을 한글로 시작한다 (게임 이름에 한글이 있거나 기기 언어가 한국어)
    static func prefersKorean(_ dish: Dish) -> Bool {
        if dish.title.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) { return true }
        return Locale.preferredLanguages.first?.hasPrefix("ko") == true
    }

    /// 일시정지 화면을 닫고(엔진은 멈춘 채) 배치 편집기를 연다. 닫으면 일시정지 화면으로 돌아온다
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
        if resume { engine.resume() }
    }

    /// 일시정지 화면에서 바꾼 패드 값은 이 게임에만 저장한다
    private func setPadHere(_ p: PadPrefs) {
        prefsStore.update(dish.id) { $0.pad = p }
    }

    /// "모든 게임에 적용": 지금 값을 전역 설정으로 쓰고 이 게임은 전역을 따르게 한다
    private func applyPadToAll() {
        PadPrefs.setGlobal(padPrefs)
        prefsStore.update(dish.id) { $0.pad = nil }
        showToast("모든 게임에 적용했어요")
    }

    /// 일시정지 화면의 컨트롤러 조작 (웹 게임 화면과 같음): 위·아래 초점, 왼·오른쪽 값, A 고르기, B·메뉴·홈 계속하기
    private func pauseInput(_ b: PadButton) {
        if showStates { stateList.handle(b); return }
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
                pauseFocus = .kind(all[min(all.count - 1, max(0, i + Int(d)))])
            case .size: p.scale = nudge(p.scale, 0.05 * d, 0.8...1.3); setPadHere(p)
            case .opacity: p.opacity = nudge(p.opacity, 0.05 * d, 0.25...0.9); setPadHere(p)
            case .volume: BingsuApp.setGameVolume(BingsuApp.gameVolume + 0.05 * d)
            case .rumbleStrength:
                let v = UserDefaults.standard.object(forKey: Rumble.strengthKey) == nil ? 0.7 : UserDefaults.standard.double(forKey: Rumble.strengthKey)
                UserDefaults.standard.set(nudge(v, 0.1 * d, 0.1...1), forKey: Rumble.strengthKey)
            default: step(Int(d))
            }
        case .a:
            var p = padPrefs
            switch pauseFocus {
            case .resume?: closePause()
            case .home?: closePause(resume: false); goHome()
            case .close?: confirmQuit = true
            case .kind(let k)?: p.kind = k; setPadHere(p)
            case .editLayout?: editLayout()
            case .keyboard?: openKeyboard()
            case .keyMap?: KeyCapture.shared.presentFor = dish.id
            case .hidePad?: if padShown { showSpoon = false } else { showSpoon = true; padForced = anyController }
            case .labels?: p.showLabels.toggle(); setPadHere(p)
            case .floating?: p.floatingStick.toggle(); setPadHere(p)
            case .leftHand?: p.leftHanded.toggle(); setPadHere(p)
            case .applyAll?: applyPadToAll()
            case .mixAudio?: BingsuApp.setPlayInSilent(!BingsuApp.playInSilent(for: dish.id), for: dish.id)
            case .rumble?: UserDefaults.standard.set(!Rumble.shared.enabled, forKey: Rumble.key)
            case .btSafe?: UserDefaults.standard.set(!Rumble.shared.btSafe, forKey: Rumble.btSafeKey)
            case .avoidCamera?: avoidCamera.toggle()
            case .hud?: showHUD.toggle()
            case .save?: saveNew()
            case .load?: openStates()
            case .more?: showSettings = true
            case nil: pauseFocus = items.first
            default: break
            }
        default: break
        }
    }

    /// 일시정지 화면에 보이는 순서대로 (PauseBoard 와 같은 조건, 소리 다시 켜기·초당 프레임·화질 없음)
    private var pauseItems: [PauseItem] {
        let p = padPrefs
        var out: [PauseItem] = [.resume, .home, .close] + (GameFrame.isDuo ? [.avoidCamera] : []) + [.keyboard]
        // 저장 묶음은 계속하기·홈으로 바로 아래 (PauseBoard 와 같은 순서)
        if scoopShown { out += [.save, .load] }
        out += PadKind.allCases.map { .kind($0) } + (p.kind == .oneHand ? [.leftHand] : []) + [.size, .opacity, .hidePad, .labels]
        if p.providesStick() { out.append(.floating) }
        out.append(.editLayout)
        if prefsStore.prefs(for: dish.id).pad != nil { out.append(.applyAll) }
        out += [.volume, .mixAudio, .rumble]
        if Rumble.shared.enabled { out += [.rumbleStrength, .btSafe] }
        out.append(.hud)
        if KeyCapture.anyInputConnected { out.append(.keyMap) }
        out.append(.more)
        return out
    }

    private func showToast(_ text: String, tone: ToastTone = .info) {
        NSLog("[BrassBowl] toast \(text)")
        withAnimation { toast = text; toastTone = tone }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { if toast == text { toast = nil } } }
    }

    // MARK: 화면 배치

    /// 게임 화면 자리 (화면 전체 좌표). 쓸 수 있는 영역을 정하고 `GameFrame.fit` 으로 비율을 지켜 가로·세로 가운데에 둔다.
    /// 세로: 눈송이 줄 아래 ~ 패드 윗줄(패드가 없으면 아래 안전 영역) 사이. 가로: 좌우 안전 영역 안, 높이 전체.
    /// 게임 키보드: 눈송이 줄(세로)·위 안전 영역 아래 ~ 키보드 위.
    /// 비율은 엔진이 알려 준 값이라 게임이 해상도를 바꾸면(`engine.gameAspect`) 다시 불린다
    private func gameRect(_ size: CGSize) -> CGRect {
        let W = size.width, H = size.height
        guard W > 0, H > 0 else { return .zero }
        let ins = GameFrame.windowInsets()
        let portrait = H > W
        let area: CGRect
        if keyboardShown {
            let kbTop = H - GameKeyboard.height(width: W, bottomInset: ins.bottom) - 6
            let top = ins.top   // 눈송이는 키보드의 메뉴 키로 — 위에 눈송이 줄을 비워 두지 않는다
            let side = GameFrame.underCamera(ins, landscape: !portrait)
            // 반 접기: 키보드는 아래 절반, 게임은 접히는 선 위에만
            let fold = hinge.pose.halfFoldLine(size: size, insets: ins)
            let bottom = fold.map { min(kbTop, $0 - 8) } ?? kbTop
            let r = CGRect(x: portrait ? 0 : side.left, y: top,
                           width: portrait ? W : W - side.left - side.right, height: max(0, bottom - top))
            area = fold == nil ? r : GameFrame.halfFoldInset(r)
        } else if portrait {
            // 눈송이가 패드 안에 있으면 위쪽 눈송이 줄은 비워 두지 않는다
            let band: CGFloat = menuButtonPlace == .pad && padShown ? 8 : BowlContainerView.chrome
            let padTop = padShown ? padLayout(size, ins: ins)?.topEdge : nil
            area = GameFrame.portraitArea(size: size, insets: ins, band: band, padTop: padTop)
        } else {
            area = GameFrame.landscapeArea(size: size, insets: ins)
            // 카메라 피하기: 위에 붙이고 남는 높이는 아래로 (−/+·메뉴 단추가 게임 대신 바탕 위에 놓인다)
            if GameFrame.avoidCamera, GameFrame.hasCameraStrip(ins) {
                return GameFrame.avoidCameraLandscape(aspect: aspect, screen: size, insets: ins)
            }
        }
        return GameFrame.fit(aspect: aspect, in: area)
    }

    private func applyViewport(_ size: CGSize) {
        engine.setSafeArea(GameFrame.windowInsets())
        engine.setViewport(gameRect(size), in: size)
    }

    private func padLayout(_ full: CGSize, ins: UIEdgeInsets) -> SpoonLayout? {
        SpoonLayout.make(prefs: padPrefs, size: full, safe: (ins.top, ins.left, ins.bottom, ins.right))
    }

    @ViewBuilder private var menuButton: some View {
        let btn = Button { openPause() } label: {
            Image(systemName: "snowflake.circle.fill")
                .font(.system(size: 28)).foregroundStyle(.white.opacity(0.7))
                .padding(10)
        }
        switch menuButtonPlace {
        case .topRight:
            CornerOrb(btn, wantLeading: false, inset: BowlContainerView.cornerInset())
        case .topLeft:
            CornerOrb(btn, wantLeading: true, inset: BowlContainerView.cornerInset())
        case .pad:
            GeometryReader { geo in
                let ins = geo.safeAreaInsets
                let full = CGSize(width: geo.size.width + ins.leading + ins.trailing, height: geo.size.height + ins.top + ins.bottom)
                let l = SpoonLayout.make(prefs: padPrefs, size: full, safe: (ins.top, ins.leading, ins.bottom, ins.trailing))
                if padShown, isPlaying, let c = l.betweenViewMenu {
                    btn.position(x: c.x - ins.leading, y: min(c.y - ins.top, geo.size.height - 22))
                } else {
                    CornerOrb(btn, wantLeading: false, inset: BowlContainerView.cornerInset())
                }
            }
        }
    }
}

/// 엔진(SDL)이 만든 창의 게임 뷰를 빙수 창 안으로 옮겨 붙인다.
/// 창 두 개를 겹치면 기기에서 합성이 깨지고, SDL 창만 쓰면 시뮬레이터가 깨진다(empo GameViewEmbedder 와 같은 이유).
/// 그래서 SDL 창은 숨기고 그 루트 뷰를 이 뷰의 자식으로 둔다. 게임 터치는 받지 않는다(패드가 받음).
struct BrassBowlHost: UIViewRepresentable {
    var onEmbed: () -> Void = {}

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.backgroundColor = .black
        v.onEmbed = onEmbed
        v.tryEmbed()
        return v
    }

    func updateUIView(_ uiView: HostView, context: Context) { uiView.onEmbed = onEmbed }

    final class HostView: UIView {
        var onEmbed: () -> Void = {}
        private weak var gameView: UIView?
        private var tries = 0

        @MainActor func tryEmbed() {
            guard gameView == nil else { return }
            if let win = BrassBowlEngine.shared.gameWindow, let gv = win.rootViewController?.view {
                gv.removeFromSuperview()
                gv.frame = bounds
                gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                gv.isUserInteractionEnabled = false
                insertSubview(gv, at: 0)
                win.isHidden = true
                gameView = gv
                pin(gv)
                // SDL 창이 키 창을 가져갔으면 빙수 창에 돌려준다 (시트·알림 입력)
                window?.makeKey()
                NSLog("[BrassBowl] 게임 화면 붙임")
                onEmbed()
                return
            }
            tries += 1
            guard tries < 600 else { NSLog("[BrassBowl] 게임 화면을 찾지 못함"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.tryEmbed() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { tryEmbed() }
        }

        /// 게임 화면은 늘 이 뷰 크기 그대로. SDL 이 백그라운드 스냅샷 때 자기 창 크기로 바꿔 둔 것도 여기서 되돌린다
        override func layoutSubviews() {
            super.layoutSubviews()
            refit()
        }

        private var pins: [NSKeyValueObservation] = []

        /// SDL 은 전체화면 전환·상태 표시줄 갱신·앱 복귀 때 게임 뷰 자리를 자기(숨은) 창 크기로 직접 바꾼다
        /// (UIKit_UpdateWindowBorder). 그때 이 뷰는 다시 배치되지 않아 layoutSubviews 만으로는 못 되돌리고,
        /// 엔진은 어긋난 뷰 크기 안에서 가운데를 잡아 게임이 한쪽으로 치우친다. 레이어 자리가 바뀌면 바로 되돌린다
        private func pin(_ gv: UIView) {
            pins = [gv.layer.observe(\.bounds) { [weak self] _, _ in self?.refitSoon() },
                    gv.layer.observe(\.position) { [weak self] _, _ in self?.refitSoon() }]
        }

        private func refitSoon() {
            if Thread.isMainThread { MainActor.assumeIsolated { refit() } }
            else { DispatchQueue.main.async { [weak self] in self?.refit() } }
        }

        private func refit() {
            guard let gv = gameView, gv.frame != bounds else { return }
            if DevEnv["BINGSU_MKXP_LOG"] == "1" { NSLog("[BrassBowl] 게임 뷰 자리 되돌림 \(gv.frame) → \(bounds)") }
            gv.frame = bounds
        }
    }
}
