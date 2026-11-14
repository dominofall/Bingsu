import Foundation
import GameController
import Combine
import os
import UIKit
import ObjectiveC

/// 하드웨어 키보드 → 게임. 키 설정(`KeyMap.keys`)을 여기서 적용한다.
///
/// - RPG Maker(SDL): SDL 은 하드웨어 키보드를 `GCKeyboard` 의 처리기 하나(`keyChangedHandler`)로 받는다.
///   빙수는 그 처리기를 감싸(`install`) 바뀐 키만 가로채고, 나머지는 SDL 에 그대로 넘긴다.
///   글자 입력 중(`HardKeyText`)에는 키를 그대로 넘기면서 글자 조합 쪽에도 같이 보낸다.
///   예전(빌드 42) `HardKeyText` 는 이 처리기를 통째로 바꿔 끼워, 글자 입력 중 Enter·Esc 가 게임에 안 가고
///   끝나면 처리기를 비워 그 뒤로 키보드가 아예 먹지 않았다 → 이제 이 감싸기 한곳만 처리기를 만진다.
/// - 웹 게임(WKWebView): 웹뷰가 키를 DOM 이벤트로 바로 받으므로 주입 스크립트(`BowlScripts.hardKeyGuard`)가 바뀐 키만
///   막고 `hardkey` 메시지로 넘긴다. 글자 칸에 커서가 있으면 막지 않는다.
/// - 바뀐 키의 결과는 가상 패드와 같은 길(`SpoonController`)로 보낸다: 패드 버튼이면 `press`, 키면 `setDirectKey`.
@MainActor
final class HardKeys {
    static let shared = HardKeys()

    /// SDL 의 키보드 큐(백그라운드)에서 읽는 값. 잠금으로 묶는다
    struct Snapshot {
        var token = UUID()
        var map: [Int: KeyTarget] = [:]          // HID 번호 → 할 일 (RPG Maker 게임이 붙어 있을 때만)
        var passthrough = false                  // 글자 입력 화면: 바꾸지 않고 그대로
        var textSink = false                     // 글자 조합(HardKeyText)에도 보내기
        var capture = false                      // 키 설정의 "키를 누르세요": 게임에 보내지 않는다
        var mappedDown: [Int: KeyTarget] = [:]   // 바뀐 채로 눌린 키 (뗄 때 같은 대상으로)
    }
    nonisolated let state = OSAllocatedUnfairLock(initialState: Snapshot())

    private weak var spoon: SpoonController?
    private(set) var dishID: String?
    private var isBrass = false
    /// 이 게임이 원래 받는 키 (지정한 키가 대신하는 원래 키를 끌 때)
    private var cutlery: CutlerySet?
    private var textSinkFn: ((GCKeyCode, Bool) -> Void)?
    private var installedOn: ObjectIdentifier?
    private var subs: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    /// 웹 게임에서 바뀐 채로 눌린 키
    private var webDown: [String: KeyTarget] = [:]

    /// 게임 키보드·두벌식 이름 입력처럼 글자를 받는 화면 (BrassBowlContainerView 가 알려 준다)
    var textScreen = false { didSet { if textScreen != oldValue { refresh() } } }

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            // SDL 도 같은 알림에서 처리기를 새로 단다. 그 뒤에 다시 감싼다
            Task { @MainActor in
                HardKeys.shared.installedOn = nil
                try? await Task.sleep(nanoseconds: 300_000_000)
                HardKeys.shared.installIfNeeded()
            }
        })
        observers.append(nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            Task { @MainActor in HardKeys.shared.installedOn = nil }
        })
    }

    // MARK: 게임 붙이기

    /// 게임 화면이 시작할 때. 이 게임의 키 설정을 쓴다
    func attach(dish: Dish, spoon: SpoonController) {
        self.spoon = spoon
        spoon.keyMapID = dish.id
        dishID = dish.id
        isBrass = dish.recipe == .mkxp
        cutlery = CutlerySet.forDish(dish)
        webDown = [:]
        subs = []
        if isBrass {
            let e = BrassBowlEngine.shared
            e.$phase.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.installIfNeeded() }.store(in: &subs)
            e.$textInputActive.receive(on: DispatchQueue.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }.store(in: &subs)
        }
        refresh()
        installIfNeeded()
        scheduleDebugKeys()
    }

    /// 디버그 `BINGSU_HARDKEYS="초:코드,…"`: 그 시각에 하드웨어 키를 누른 것처럼 (0.15초 뒤 뗌).
    /// 시뮬레이터의 키 입력은 게임 화면까지 오지 않아서, OS 가 넘겨 준 다음 단계(감싼 처리기·웹 `hardkey` 메시지)부터 확인한다.
    /// RPG Maker 는 감싼 처리기와 같은 길 고르기 → 바뀐 키는 보내고 나머지는 SDL 이 받은 것처럼 엔진에 넣는다.
    private func scheduleDebugKeys() {
        guard let spec = DevEnv["BINGSU_HARDKEYS"] else { return }
        for item in spec.split(separator: ",") {
            let parts = item.split(separator: ":")
            guard parts.count == 2, let t = Double(parts[0]), KeyCatalog.isKnown(String(parts[1])) else { continue }
            let code = String(parts[1])
            for (dt, down) in [(t, true), (t + 0.15, false)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + dt) { HardKeys.shared.debugKey(code, down: down) }
            }
        }
    }

    private func debugKey(_ code: String, down: Bool) {
        NSLog("[Keys] debug hardware \(code) \(down)")
        if isBrass {
            guard let hid = KeyCatalog.hid(code) else { return }
            switch state.withLock({ Self.route(&$0, token: $0.token, raw: hid, pressed: down) }) {
            case .mapped(let t): perform(t, down: down, from: hid)
            case .swallow: break
            case .pass, .text: BrassBowlEngine.shared.key(Int32(hid), down: down)
            }
        } else {
            spoon?.webView?.evaluateJavaScript("window.webkit.messageHandlers.hardkey.postMessage({code:'\(code)',down:\(down)})", completionHandler: nil)
        }
    }

    func detach(spoon: SpoonController) {
        guard self.spoon === spoon else { return }
        self.spoon = nil; dishID = nil; isBrass = false; subs = []; webDown = [:]; textScreen = false; cutlery = nil
        refresh()
    }

    /// 키 설정이 바뀌었다
    func mapChanged() {
        refresh()
        pushWeb()
    }

    private var map: KeyMap { KeyMapStore.shared.effective(dishID) }
    /// 실제로 쓸 키 표 (원래 키 끄기까지)
    private var keyTable: [String: KeyTarget] { map.gameKeys(cutlery) }

    private func refresh() {
        var hid: [Int: KeyTarget] = [:]
        if isBrass { for (code, t) in keyTable { if let h = KeyCatalog.hid(code) { hid[h] = t } } }
        let pass = textScreen || (isBrass && BrassBowlEngine.shared.textInputActive)
        state.withLock { $0.map = hid; $0.passthrough = pass }
    }

    // MARK: RPG Maker: SDL 의 키보드 처리기 감싸기

    private func installIfNeeded() {
        guard isBrass, let id = dishID, BrassBowlEngine.shared.phase == .playing(dishID: id) || textSinkFn != nil else { return }
        installPressHook()
        guard let kb = GCKeyboard.coalesced, let input = kb.keyboardInput else {
            if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[Keys] GCKeyboard 없음 (UIKit 키 입력 길)") }
            return
        }
        guard installedOn != ObjectIdentifier(kb) else { return }
        let token = UUID()
        state.withLock { $0.token = token; $0.mappedDown = [:] }
        input.keyChangedHandler = Self.handler(state: state, token: token, downstream: input.keyChangedHandler)
        installedOn = ObjectIdentifier(kb)
        if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[Keys] 하드웨어 키보드 처리기 감쌈") }
    }

    enum Route: Equatable { case pass, mapped(KeyTarget), swallow, text }

    /// 키 하나를 어디로 보낼지 (자가 테스트도 이것을 부른다)
    nonisolated static func route(_ s: inout Snapshot, token: UUID, raw: Int, pressed: Bool) -> Route {
        guard s.token == token else { return .pass }
        if let t = s.mappedDown[raw] {
            if !pressed { s.mappedDown[raw] = nil }
            return .mapped(t)
        }
        if s.capture { return .swallow }
        if s.textSink { return .text }
        if !s.passthrough, pressed, let t = s.map[raw] { s.mappedDown[raw] = t; return .mapped(t) }
        return .pass
    }

    /// 감싼 처리기. 어느 큐에서나 불린다(SDL 은 자기 백그라운드 큐). 예전 감싸기(토큰이 다름)는 그대로 넘기기만 한다
    nonisolated private static func handler(state: OSAllocatedUnfairLock<Snapshot>, token: UUID,
                                            downstream: GCKeyboardValueChangedHandler?) -> GCKeyboardValueChangedHandler {
        return { input, button, code, pressed in
            let raw = Int(code.rawValue)
            let r = state.withLock { Self.route(&$0, token: token, raw: raw, pressed: pressed) }
            switch r {
            case .pass: downstream?(input, button, code, pressed)
            case .swallow: break
            case .text:
                downstream?(input, button, code, pressed)
                DispatchQueue.main.async { MainActor.assumeIsolated { HardKeys.shared.textSinkFn?(code, pressed) } }
            case .mapped(let t):
                DispatchQueue.main.async { MainActor.assumeIsolated { HardKeys.shared.perform(t, down: pressed, from: raw) } }
            }
        }
    }

    // MARK: RPG Maker: GCKeyboard 가 없을 때의 UIKit 길

    private var pressHooked = false

    /// GCKeyboard 로 잡히지 않는 키보드(시뮬레이터의 하드웨어 키 입력 등)는 SDL 이 UIKit `pressesBegan` 으로 받는다.
    /// 그 길도 같은 규칙으로 바꾸도록 SDL 의 게임 뷰(`SDL_uikitview`) 메서드를 한 번 감싼다. 엔진 소스는 그대로.
    /// GCKeyboard 가 있으면 SDL 은 이 길을 쓰지 않으므로(SDL_HasGCKeyboard) 손대지 않고 넘긴다.
    private func installPressHook() {
        guard !pressHooked, let cls = NSClassFromString("SDL_uikitview") else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, NSSet, UIPressesEvent?) -> Void
        for (name, down) in [("pressesBegan:withEvent:", true), ("pressesEnded:withEvent:", false), ("pressesCancelled:withEvent:", false)] {
            let sel = NSSelectorFromString(name)
            guard let m = class_getInstanceMethod(cls, sel) else { continue }
            let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
            let block: @convention(block) (AnyObject, NSSet, UIPressesEvent?) -> Void = { obj, presses, event in
                let rest = MainActor.assumeIsolated { HardKeys.shared.filterPresses(presses, down: down) }
                if rest.count > 0 { orig(obj, sel, rest, event) }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        pressHooked = true
        if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[Keys] SDL UIKit 키 입력 감쌈") }
    }

    /// 바뀐 키는 빼고(여기서 보내고) 나머지만 SDL 에 넘긴다
    private func filterPresses(_ presses: NSSet, down: Bool) -> NSSet {
        guard GCKeyboard.coalesced == nil else { return presses }
        var rest: [UIPress] = []
        for case let p as UIPress in presses {
            guard let key = p.key else { rest.append(p); continue }
            let raw = Int(key.keyCode.rawValue)
            let r = state.withLock { Self.route(&$0, token: $0.token, raw: raw, pressed: down) }
            switch r {
            case .pass, .text: rest.append(p)
            case .swallow: break
            case .mapped(let t): perform(t, down: down, from: raw)
            }
        }
        return NSSet(array: rest)
    }

    /// 글자 조합(HardKeyText)에 하드웨어 키를 같이 보낸다. nil 이면 멈춘다
    func setTextSink(_ f: ((GCKeyCode, Bool) -> Void)?) {
        textSinkFn = f
        state.withLock { $0.textSink = f != nil }
        if f != nil { installIfNeeded() }
    }

    /// 키 설정 화면에서 키를 기다리는 동안 게임에 키를 보내지 않는다
    func setCapture(_ on: Bool) { state.withLock { $0.capture = on } }

    // MARK: 웹 게임

    /// 웹 게임 주입 스크립트가 처음 막을 키 (GlassBowl 이 웹뷰를 만들 때)
    func webCodes(for dish: Dish) -> [String] { KeyMapStore.shared.effective(dish.id).gameKeys(CutlerySet.forDish(dish)).keys.sorted() }

    /// 주입 스크립트가 막은 키 (`hardkey` 메시지, 값은 GlassBowl 이 검사한 뒤)
    func webKey(_ code: String, down: Bool) {
        guard !isBrass, spoon != nil, KeyCatalog.isKnown(code) else { return }
        if down {
            guard webDown[code] == nil else { return }
            // 막힌 뒤 설정이 바뀌어 대상이 없으면 원래 키 그대로
            let t = keyTable[code] ?? .key(code)
            webDown[code] = t
            perform(t, down: true, from: nil)
        } else if let t = webDown.removeValue(forKey: code) {
            perform(t, down: false, from: nil)
        }
    }

    private func pushWeb() {
        guard !isBrass, dishID != nil, let wv = spoon?.webView,
              let data = try? JSONSerialization.data(withJSONObject: keyTable.keys.sorted()), let json = String(data: data, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.__bingsuHardKeys&&__bingsuHardKeys.set(\(json))", completionHandler: nil)
    }

    // MARK: 결과 보내기

    private func perform(_ t: KeyTarget, down: Bool, from hid: Int?) {
        guard let spoon else { return }
        if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[Keys] hardware \(hid.flatMap(KeyCatalog.code(hid:)) ?? "web") → \(t.stored) \(down)") }
        switch t {
        case .pad(let b): if down { spoon.press(b, haptic: false) } else { spoon.release(b) }
        case .key(let c): spoon.setDirectKey(c, down: down)
        case .off: break
        }
    }
}

/// 키 설정 화면의 "버튼을 누르세요": 컨트롤러·하드웨어 키보드를 60Hz 로 직접 읽어 새로 눌린 것 하나를 잡는다.
/// 처리기를 바꿔 끼우지 않으므로 게임 쪽(LongSpoon·SDL)과 부딪치지 않는다. 기다리는 동안 게임에는 보내지 않는다.
@MainActor
final class KeyCapture: ObservableObject {
    static let shared = KeyCapture()
    enum Kind: Equatable { case pad, key }

    @Published private(set) var waiting: Kind?
    /// 기다리는 종류의 기기가 연결돼 있는지 (기다리는 동안 계속 살핀다 — 연결하면 바로 바뀐다)
    @Published private(set) var connected = false
    /// 키 설정 화면이 열려 있는 수. 열려 있으면 실제 컨트롤러 입력을 게임·일시정지 화면에 보내지 않는다 (LongSpoon)
    @Published private(set) var openCount = 0
    var isOpen: Bool { openCount > 0 }
    /// 일시정지 화면에서 키 설정 시트를 열 게임 id (컨트롤러 A 로 열 때 게임 화면이 정한다)
    @Published var presentFor: String?

    private var timer: Timer?
    private var prevPads: Set<PadButton> = []
    private var prevKeys: Set<Int> = []
    private var onPad: ((PadButton) -> Void)?
    private var onKey: ((String) -> Void)?

    func screenAppeared() { openCount += 1 }
    func screenDisappeared() { openCount = max(0, openCount - 1); if openCount == 0 { cancel() } }

    func begin(_ kind: Kind, onPad: ((PadButton) -> Void)? = nil, onKey: ((String) -> Void)? = nil) {
        cancel()
        receivedToken += 1; received = nil
        waiting = kind
        self.onPad = onPad; self.onKey = onKey
        prevPads = Self.pads(); prevKeys = Self.keys()
        connected = kind == .pad ? Self.controllerConnected : Self.keyboardConnected
        HardKeys.shared.setCapture(true)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { KeyCapture.shared.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        waiting = nil; onPad = nil; onKey = nil
        HardKeys.shared.setCapture(false)
    }

    /// 받은 버튼·키 ("X 버튼을 받았어요") — 잡은 뒤 잠깐 "받았어요"를 보여 준다
    @Published private(set) var received: String?
    private var receivedToken = 0

    /// 잡은 것 (실제로 누른 것)
    func choose(pad b: PadButton) { let f = onPad; cancel(); lastCaptureAt = Date(); showReceived("\(b.displayName) 버튼을 받았어요"); f?(b) }
    func choose(key c: String) { let f = onKey; cancel(); lastCaptureAt = Date(); showReceived("\(KeyCatalog.label(c)) 키를 받았어요"); f?(c) }

    private func showReceived(_ text: String) {
        receivedToken += 1
        let tok = receivedToken
        received = text
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.receivedHold) { [weak self] in
            guard let self, self.receivedToken == tok else { return }
            self.received = nil
        }
    }
    /// 마지막으로 잡은 때 (잡은 그 B 버튼이 화면 닫기로 읽히지 않게)
    private(set) var lastCaptureAt = Date.distantPast

    private func poll() {
        if let w = waiting {
            let c = w == .pad ? Self.controllerConnected : Self.keyboardConnected
            if c != connected { connected = c }
        }
        switch waiting {
        case .pad?:
            let now = Self.pads()
            let new = now.subtracting(prevPads); prevPads = now
            if let b = KeyMap.remappable.first(where: new.contains) { choose(pad: b) }
        case .key?:
            let now = Self.keys()
            let new = now.subtracting(prevKeys); prevKeys = now
            if let c = new.sorted().compactMap(KeyCatalog.code(hid:)).first { choose(key: c) }
        case nil: break
        }
    }

    static func pads() -> Set<PadButton> {
        var out: Set<PadButton> = []
        for c in GCController.controllers() where !c.isSnapshot { if let p = c.extendedGamepad { out.formUnion(LongSpoon.pressed(p)) } }
        return out
    }

    static func keys() -> Set<Int> {
        guard let kb = GCKeyboard.coalesced?.keyboardInput else { return [] }
        var out: Set<Int> = []
        for e in KeyCatalog.all where kb.button(forKeyCode: GCKeyCode(rawValue: CFIndex(e.hid)))?.isPressed == true { out.insert(e.hid) }
        return out
    }

    static var controllerConnected: Bool { demo || LongSpoon.anyRealGamepad() }
    static var keyboardConnected: Bool { demo || GCKeyboard.coalesced != nil }
    /// 일시정지의 "컨트롤러·키보드" 묶음을 보일지 (PauseBoard 와 같은 조건)
    static var anyInputConnected: Bool { !LongSpoon.connectedNames().isEmpty || controllerConnected || keyboardConnected }

    /// 디버그 `BINGSU_CAPTURE_DEMO=1`: 연결된 것처럼 "입력을 받고 있어요"를 보이고 "받았어요"를 오래 보인다 (시뮬레이터 스크린숏용)
    #if DEBUG
    private static let demo = DevEnv["BINGSU_CAPTURE_DEMO"] == "1"
    #else
    private static let demo = false
    #endif
    private static var receivedHold: Double { demo ? 6 : 0.9 }
    /// 바꾼 줄이 밝게 남는 시간
    static var flashHold: Double { demo ? 7 : 1.2 }
}
