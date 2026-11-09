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
    @State private var startError: String?
    @State private var showMenu = false
    @State private var pauseFocus: PauseItem?
    @State private var lastBackup: Date?
    @State private var showSettings = false
    /// 배치 편집 (일시정지 화면 › 배치 편집). 엔진은 멈춘 채 그 위에 편집기를 띄운다
    @State private var showEditor = false
    @State private var confirmQuit = false
    /// RTP 가 없는 게임을 처음 열 때 한 번 안내한다 (DishPrefs.rtpNoticeShown)
    @State private var rtpNotice = false
    @State private var textEntry = ""
    @State private var fpsTimer: Timer?
    @State private var controllerConnected = BowlContainerView.realGamepadConnected()
    @ObservedObject private var watch = TeaSpoonLink.shared
    @AppStorage(TeaSpoonLink.enabledKey) private var watchEnabled = true
    @State private var showSpoon = true
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
    private var watchConnected: Bool { watchEnabled && watch.reachable && watch.watchAppInstalled }
    private var anyController: Bool { controllerConnected || watchConnected }
    private var padShown: Bool { showSpoon && (!anyController || padForced) }
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
                    .onChange(of: engine.gameAspect) { _, _ in applyViewport(geo.size) }
                if !isPlaying {
                    loadingCover.frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                }
            }
            .ignoresSafeArea()

            if padShown && isPlaying && !showEditor { SpoonOverlay(controller: spoon, prefs: padPrefs) }

            if showHUD {
                VStack {
                    HStack { ThermometerHUD(thermometer: thermometer); Spacer() }.padding(.horizontal, 12).padding(.top, 8)
                    Spacer()
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
            if case .ended(let id, let clean) = engine.phase, id == dish.id { endedCover(clean: clean) }
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
        .alert("게임을 끝낼까요?", isPresented: $confirmQuit) {
            Button("끝내기", role: .destructive) { quit() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("게임 안에서 저장하지 않은 진행은 사라져요. 이 게임은 끝낸 뒤 빙수를 다시 열어야 다시 할 수 있어요.")
        }
        .alert("RTP 가 필요해요", isPresented: $rtpNotice) {
            Button("그냥 열기") { rtpNoticeDone(); startEngine() }
            Button("목록으로", role: .cancel) { rtpNoticeDone(); onClose() }
        } message: {
            Text("이 게임은 공용 그림·소리 묶음(RTP · \(dish.rtp ?? ""))을 따로 써요. RTP 폴더를 zip 으로 묶어 게임 추가 › RTP 넣기로 넣어 주세요. RTP 설치 파일(exe)은 넣을 수 없어요. 그냥 열면 그림이나 소리가 빠질 수 있어요.")
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
        // 이름 입력처럼 게임이 글자를 기다릴 때: 한 번에 받아 넣고 Enter
        .alert("글자 입력", isPresented: Binding(get: { engine.textInputActive && visible }, set: { _ in })) {
            TextField("이름", text: $textEntry)
            Button("입력") { submitText() }
        } message: {
            Text("게임에 넣을 글자를 입력하세요")
        }
        .sheet(isPresented: $showSettings) { DishSettingsView(dish: dish) }
        .onChange(of: padPrefs.haptics) { _, on in spoon.hapticsEnabled = on }
        .onChange(of: scenePhase) { _, phase in
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
            if v { engine.resume() } else { engine.pause() }
        }
        .onChange(of: engine.phase) { _, p in
            if case .ended(let id, _) = p, id == dish.id { spoon.releaseAll() }   // 저장 묶기·올리기는 엔진이 끝날 때 BrassBowlEngine 이
        }
        .onAppear(perform: start)
        .onDisappear {
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
        spoon.hapticsEnabled = padPrefs.haptics
        spoon.keySink = { code, down in
            guard let sc = BrassKeys.scancode(code) else { return }
            if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[BrassBowl] key \(code)=\(sc) \(down)") }
            BrassBowlEngine.shared.key(sc, down: down)
        }
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
        // iCloud·백업 되돌리기로 save.json 이 바뀌었으면 Game.rxdata 로 풀어 둔다 (게임이 켜지기 전)
        IceTray.sync(dish, allowUnpack: true)
        if let err = engine.start(.init(dish: dish, savesDir: freezer.directory)) {
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
    }

    /// 디버그: BINGSU_KEYS="초:코드,..." 면 그 시각에 키를 짧게 누른다 (예: "12:Enter,15:KeyC"). 시뮬레이터 자동 확인용
    private func debugKeys() {
        // BINGSU_AUTOKEY="코드:간격초:횟수" 면 그 키를 계속 누른다(긴 대사 넘기기). 글자 입력 창이 뜨면 멈춤
        if let spec = DevEnv["BINGSU_AUTOKEY"] {
            let p = spec.split(separator: ":")
            if p.count == 3, let sc = BrassKeys.scancode(String(p[0])), let gap = Double(p[1]), let n = Int(p[2]) {
                for i in 0..<n {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12 + gap * Double(i)) {
                        let e = BrassBowlEngine.shared
                        guard !e.textInputActive, e.runningDishID != nil else { return }
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
        IceTray.sync(dish, allowUnpack: !stillRunning)
        Igloo.shared.afterPlay(dish, stillRunning: stillRunning)
    }

    private func backup() {
        IceTray.sync(dish, allowUnpack: false)
        showToast(freezer.freeze() != nil ? "백업했어요" : "아직 게임 안에서 저장한 데이터가 없어요")
        lastBackup = freezer.backups().first?.date
    }

    private func submitText() {
        let t = textEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        textEntry = ""
        if !t.isEmpty { engine.pushText(t) }
        // Enter 는 글자가 들어간 뒤에. 같은 프레임에 오면 Essentials 이름 입력은 Enter 를 먼저 보고
        // 그 프레임의 글자 읽기(Input.gets)를 건너뛰어, 빈 이름으로 끝나거나 글자가 안 들어간다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            BrassBowlEngine.shared.key(40, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { BrassBowlEngine.shared.key(40, down: false) }
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
            runningQuality: .high, showHUD: $showHUD, lastBackup: lastBackup,
            onResume: { closePause() },
            onHome: { closePause(resume: false); goHome() },
            onClose: { confirmQuit = true },
            onBackup: backup, onMoreSettings: { showSettings = true },
            onEditLayout: editLayout,
            focus: $pauseFocus)
    }

    /// 일시정지: 엔진을 멈추고 패드 입력을 놓은 뒤 화면을 연다. 컨트롤러 입력은 화면 조작으로 돌린다
    private func openPause() {
        guard !showMenu, isPlaying else { return }
        spoon.releaseAll()
        engine.pause()
        IceTray.sync(dish, allowUnpack: false)
        lastBackup = freezer.backups().first?.date
        pauseFocus = anyController ? .resume : nil
        longSpoon?.menuInput = { b in pauseInput(b) }
        teaSpoon?.menuInput = { b in pauseInput(b) }
        TeaSpoonLink.shared.setContext(game: dish.title, state: .paused)
        withAnimation(.easeOut(duration: 0.22)) { showMenu = true }
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

    /// 일시정지 화면에 보이는 순서대로 (PauseBoard 와 같은 조건, 소리 다시 켜기·초당 프레임·화질 없음)
    private var pauseItems: [PauseItem] {
        let p = padPrefs
        var out: [PauseItem] = [.resume, .home, .close] + PadKind.allCases.map { .kind($0) } + [.editLayout] + (p.kind == .oneHand ? [.leftHand] : []) + [.size, .opacity, .hidePad, .labels]
        if p.providesStick() { out.append(.floating) }
        if prefsStore.prefs(for: dish.id).pad != nil { out.append(.applyAll) }
        out += [.volume, .mixAudio, .rumble]
        if Rumble.shared.enabled { out += [.rumbleStrength, .btSafe] }
        out += [.hud, .backup, .more]
        return out
    }

    private func showToast(_ text: String) {
        NSLog("[BrassBowl] toast \(text)")
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { if toast == text { toast = nil } } }
    }

    // MARK: 화면 배치

    /// 게임 화면 자리 (화면 전체 좌표). 가로: 높이를 채운 게임 비율 가운데. 세로: 폭을 채운 게임 비율을 눈송이 줄 아래 ~ 패드 윗줄 사이, 패드 쪽으로 치우치게
    private func gameRect(_ size: CGSize) -> CGRect {
        let W = size.width, H = size.height
        guard W > 0, H > 0 else { return .zero }
        if H > W {
            let ins = Self.windowInsets()
            let gameW = W, gameH = W / aspect
            // 눈송이가 패드 안에 있으면 위쪽 눈송이 줄은 비워 두지 않는다
            let top = ins.top + (menuButtonPlace == .pad && padShown ? 8 : BowlContainerView.chrome)
            let padTop = padShown ? padLayout(size, ins: ins)?.topEdge.map { $0 - 12 } ?? H : H
            let slack = max(0, padTop - top - gameH)
            // 남는 공간에서 패드 쪽으로 치우치게 (위 3 : 아래 1)
            // 패드가 없으면(컨트롤러 연결 등) 창의 위아래 가운데. 눈송이 줄은 가리지 않는다
            return CGRect(x: 0, y: padShown ? top + slack * 0.75 : max(top, (H - gameH) / 2), width: gameW, height: gameH)
        }
        let gameH = H, gameW = min(W, H * aspect)
        return CGRect(x: (W - gameW) / 2, y: 0, width: gameW, height: gameH)
    }

    private func applyViewport(_ size: CGSize) {
        engine.setSafeArea(Self.windowInsets())
        engine.setViewport(gameRect(size), in: size)
    }

    private static func windowInsets() -> UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets ?? scenes.first?.windows.first?.safeAreaInsets ?? .zero
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
            VStack { HStack { Spacer(); btn }; Spacer() }.padding(BowlContainerView.cornerInset()).ignoresSafeArea()
        case .topLeft:
            VStack { HStack { btn; Spacer() }; Spacer() }.padding(BowlContainerView.cornerInset()).ignoresSafeArea()
        case .pad:
            GeometryReader { geo in
                let ins = geo.safeAreaInsets
                let full = CGSize(width: geo.size.width + ins.leading + ins.trailing, height: geo.size.height + ins.top + ins.bottom)
                let l = SpoonLayout.make(prefs: padPrefs, size: full, safe: (ins.top, ins.leading, ins.bottom, ins.trailing))
                if padShown, isPlaying, let c = l.betweenViewMenu {
                    btn.position(x: c.x - ins.leading, y: min(c.y - ins.top, geo.size.height - 22))
                } else {
                    VStack { HStack { Spacer(); btn }; Spacer() }.padding(BowlContainerView.cornerInset()).ignoresSafeArea()
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
            if let gv = gameView, gv.frame != bounds { gv.frame = bounds }
        }
    }
}
