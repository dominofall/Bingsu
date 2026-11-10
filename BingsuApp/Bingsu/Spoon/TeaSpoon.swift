import Foundation
import Combine
import WatchConnectivity

/// 찻숟가락: 애플워치 컨트롤러 (docs/watch/research.md 7장). iPhone 전용, 턴제 조작용 보조 입력.
/// `TeaSpoonLink` 가 WCSession 을 하나 들고 메시지를 받아, 지금 게임 화면의 `TeaSpoon` 으로 넘긴다.
/// `TeaSpoon` 은 `LongSpoon` 과 같은 모양(enabled · menuInput · onHomeButton)이라 게임 화면 쪽 변경이 적다.
@MainActor
final class TeaSpoon {
    private weak var spoon: SpoonController?
    /// 게임이 화면에 없을 때는 입력을 게임에 보내지 않는다. 켜지면 이 화면이 워치 입력을 받는다
    var enabled = true {
        didSet {
            if enabled { TeaSpoonLink.shared.target = self; TableSpoonLink.shared.target = self }
            else {
                if TeaSpoonLink.shared.target === self { TeaSpoonLink.shared.target = nil }
                if TableSpoonLink.shared.target === self { TableSpoonLink.shared.target = nil }
                releaseHeld()
            }
        }
    }
    /// 일시정지 화면이 열려 있으면 버튼을 게임에 보내지 않고 여기로 넘긴다
    var menuInput: ((PadButton) -> Void)? { didSet { releaseHeld() } }
    /// 워치의 ⌂ (≡ 길게): 일시정지 화면 열기
    var onHomeButton: (() -> Void)?

    private var held: [PadButton: Date] = [:]
    private var holdWatch: Timer?
    /// 스틱이 기울어 있는 동안 마지막으로 값이 온 시각 (iPhone 컨트롤러). 끊기면 가운데로
    private var stickAt: Date?

    init(spoon: SpoonController) {
        self.spoon = spoon
        TeaSpoonLink.shared.target = self
        TableSpoonLink.shared.target = self   // iPad: iPhone 컨트롤러 (같은 handle 로 받는다)
    }

    deinit {
        holdWatch?.invalidate()
    }

    /// 메인 스레드에서 호출. 답장 값: 받았으면 true, 게임이 없어 버렸으면 false
    @discardableResult
    func handle(button raw: Int, event: TeaWire.Event) -> Bool {
        guard enabled, let s = spoon else { return false }
        if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[TeaSpoon] 받음 b=\(raw) e=\(event) menu=\(menuInput != nil)") }
        if event == .releaseAll { releaseHeld(); return true }
        guard let b = PadButton(rawValue: raw) else { return false }
        if b == .home {
            if event == .tap || event == .down { if let menuInput { menuInput(.home) } else { onHomeButton?() } }
            return true
        }
        if let menuInput {
            if event == .tap || event == .down { menuInput(b) }
            return true
        }
        switch event {
        case .tap:
            s.press(b, haptic: false); s.release(b)   // minPress 가 뗌을 붙잡아 둔다
        case .down:
            held[b] = Date(); s.press(b, haptic: false); armHoldWatch()
        case .heartbeat:
            if held[b] != nil { held[b] = Date() } else { held[b] = Date(); s.press(b, haptic: false); armHoldWatch() }
        case .up:
            held[b] = nil; s.release(b)
        case .ping, .releaseAll, .rumble, .context, .stick:
            break
        }
        return true
    }

    /// iPhone 컨트롤러의 스틱. 일시정지 화면이 열려 있으면 버린다 (메뉴는 버튼으로)
    func handleStick(left: CGVector, right: CGVector) {
        guard enabled, let s = spoon, menuInput == nil else { return }
        if DevEnv["BINGSU_KEYDEBUG"] == "1" { NSLog("[TeaSpoon] 스틱 L(\(String(format: "%.2f,%.2f", left.dx, left.dy))) R(\(String(format: "%.2f,%.2f", right.dx, right.dy)))") }
        s.setStick(right: false, vector: left)
        s.setStick(right: true, vector: right)
        if left == .zero && right == .zero { stickAt = nil } else { stickAt = Date(); armHoldWatch() }
    }

    /// 하트비트가 끊긴 버튼을 놓는다 (뗌 메시지 유실 대비, 연구 8.2 "안 떼짐")
    private func armHoldWatch() {
        guard holdWatch == nil else { return }
        holdWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHeld() }
        }
    }

    private func checkHeld() {
        let now = Date()
        for (b, at) in held where now.timeIntervalSince(at) > TeaWire.holdTimeout {
            held[b] = nil; spoon?.release(b, immediate: true)
            NSLog("[TeaSpoon] \(b.name) 하트비트 끊김 → 놓음")
        }
        if let at = stickAt, now.timeIntervalSince(at) > TeaWire.holdTimeout {
            stickAt = nil; spoon?.setStick(right: false, vector: .zero); spoon?.setStick(right: true, vector: .zero)
            NSLog("[TeaSpoon] 스틱 하트비트 끊김 → 가운데")
        }
        if held.isEmpty && stickAt == nil { holdWatch?.invalidate(); holdWatch = nil }
    }

    private func releaseHeld() {
        for b in held.keys { spoon?.release(b, immediate: true) }
        held.removeAll()
        if stickAt != nil { stickAt = nil; spoon?.setStick(right: false, vector: .zero); spoon?.setStick(right: true, vector: .zero) }
        holdWatch?.invalidate(); holdWatch = nil
    }
}

/// WCSession 하나. 앱 시작 때 `activate()`. 델리게이트 세 가지를 다 구현해야 워치를 바꿀 때 앱이 죽지 않는다 (연구 8.2 ④)
final class TeaSpoonLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = TeaSpoonLink()
    /// 설정 "애플워치로 조작" (기본 켬). 끄면 메시지는 받되 버린다
    static let enabledKey = "bingsu.watchController"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    @Published private(set) var supported = WCSession.isSupported()
    @Published private(set) var paired = false
    @Published private(set) var watchAppInstalled = false
    @Published private(set) var reachable = false
    @Published private(set) var lastInputAt: Date?
    @Published private(set) var received = 0

    /// 지금 워치 입력을 받을 게임 화면 (없으면 버리고 답장 k=0)
    @MainActor weak var target: TeaSpoon?

    private var lastSeq = -1
    private var context: [String: Any] = [:]

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
    }

    /// 설정 화면 문구
    var statusLabel: String {
        if !supported { return "이 기기는 지원하지 않아요" }
        if !paired { return "짝지은 워치 없음" }
        if !watchAppInstalled { return "워치에 빙수 없음" }
        return reachable ? "연결됨" : "워치 앱을 열면 연결돼요"
    }

    /// 워치 화면에 보여 줄 게임 이름·상태. 바뀐 값만 보낸다 (updateApplicationContext 는 마지막 값만 남는다)
    func setContext(game: String, state: TeaWire.State) {
        TableSpoonLink.shared.setContext(game: game, state: state)   // iPad → iPhone 컨트롤러에도 같은 내용
        let next: [String: Any] = [TeaWire.game: game, TeaWire.state: state.rawValue, TeaWire.enabled: Self.isEnabled]
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { context = next; return }
        if let old = context as? [String: AnyHashable], let new = next as? [String: AnyHashable], old == new { return }
        context = next
        do { try WCSession.default.updateApplicationContext(next) } catch { NSLog("[TeaSpoon] context: \(error.localizedDescription)") }
    }

    /// 설정을 바꾸면 워치에도 알린다
    func refreshContext() {
        let game = context[TeaWire.game] as? String ?? ""
        let state = TeaWire.State(rawValue: context[TeaWire.state] as? String ?? "") ?? .home
        context = [:]
        setContext(game: game, state: state)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { NSLog("[TeaSpoon] 활성화 실패: \(error.localizedDescription)") }
        DispatchQueue.main.async {
            self.readState(session)
            // 활성화 전에 쌓인 값이 있으면 그것을, 없으면 "홈"을 보낸다 — 워치에 지난번 게임 상태가 남아 있지 않게
            let c = self.context; self.context = [:]
            self.setContext(game: c[TeaWire.game] as? String ?? "", state: TeaWire.State(rawValue: c[TeaWire.state] as? String ?? "") ?? .home)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 워치를 바꾼 뒤: 다시 활성화해야 새 워치와 이어진다
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.readState(session) }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.readState(session) }
    }

    private func readState(_ s: WCSession) {
        paired = s.isPaired; watchAppInstalled = s.isWatchAppInstalled; reachable = s.isReachable
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let sentAt = message[TeaWire.sentAt] as? Double ?? 0
        let ok = dispatch(message)
        replyHandler([TeaWire.ok: ok ? 1 : 0, TeaWire.sentAt: sentAt])
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        _ = dispatch(message)
    }

    /// 백그라운드 스레드에서 온다. 메인으로 넘겨 처리하되 답장은 바로 한다 (처리 결과는 설정이 켜져 있고 화면이 있는지로 판단)
    private func dispatch(_ message: [String: Any]) -> Bool {
        guard let raw = message[TeaWire.event] as? Int, let event = TeaWire.Event(rawValue: raw) else { return false }
        let seq = message[TeaWire.seq] as? Int ?? 0
        let button = message[TeaWire.button] as? Int ?? -1
        if event == .ping { return true }
        guard Self.isEnabled else { return false }
        let accepted = DispatchQueue.main.sync { () -> Bool in
            // 역순·중복은 버린다 (워치 앱이 다시 켜지면 번호가 0 부터라 크게 뒤로 가면 받아 준다)
            if seq <= lastSeq && lastSeq - seq < 1000 { return false }
            lastSeq = seq
            received += 1; lastInputAt = Date()
            return MainActor.assumeIsolated { target?.handle(button: button, event: event) ?? false }
        }
        return accepted
    }
}
