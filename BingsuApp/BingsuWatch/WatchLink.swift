import Foundation
import Combine
import WatchConnectivity
import WatchKit

/// 워치 쪽 WCSession. 버튼을 `sendMessage` + 답장으로 보내고 왕복 시간을 잰다 (연구 8장 P2)
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var activated = false
    @Published private(set) var reachable = false
    @Published private(set) var game = ""
    @Published private(set) var state = TeaWire.State.home
    @Published private(set) var enabled = true
    /// 왕복 시간 기록 (초)
    @Published private(set) var rtts: [Double] = []
    @Published private(set) var errors = 0
    @Published private(set) var rejected = 0     // 답장 k=0: iPhone 이 받았지만 게임 화면이 없어 버림
    @Published private(set) var lastError = ""
    @Published private(set) var measuring = false

    private var seq = 0
    /// 이번 실행의 표식. 앱이 다시 켜지면 바뀌어 iPhone 이 일련번호를 새로 센다 (2026-11-10: 시계로 나갔다 오면 앱이 다시 켜져 0 부터 보내는데
    /// iPhone 은 지난 번호보다 작다고 버려서, 지난 번호를 넘을 때까지 어느 버튼도 안 먹던 문제)
    private let run = Int.random(in: 1...Int(Int32.max))
    private var heartbeats: [Int: Timer] = [:]

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var statusLabel: String {
        // 보드 "첫 줄 문구" 표 (design/watch-board.html). 조작 불가일 때 패드 위에 세 줄로 덮인다
        if !activated { return "연결 준비 중" }
        if !reachable { return "iPhone 에서\n빙수를 열어 주세요" }
        if !enabled { return "설정 › 컨트롤러에서\n켤 수 있어요" }
        switch state {
        case .home: return "iPhone 에서\n게임을 시작하면\n조작할 수 있어요"
        case .playing: return game.isEmpty ? "게임 중" : game
        case .paused: return "일시정지 · 크라운으로 고르고 A"
        }
    }

    var canPlay: Bool { reachable && enabled && state != .home }

    // MARK: 보내기

    func tap(_ b: TeaWire.Button) { send(b.rawValue, .tap); click(b) }

    func down(_ b: TeaWire.Button) {
        send(b.rawValue, .down); click(b)
        heartbeats[b.rawValue]?.invalidate()
        heartbeats[b.rawValue] = Timer.scheduledTimer(withTimeInterval: TeaWire.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.send(b.rawValue, .heartbeat)
        }
    }

    func up(_ b: TeaWire.Button) {
        heartbeats[b.rawValue]?.invalidate(); heartbeats[b.rawValue] = nil
        send(b.rawValue, .up)
    }

    func releaseAll() {
        for t in heartbeats.values { t.invalidate() }
        heartbeats.removeAll()
        send(-1, .releaseAll)
    }

    /// 앱이 백그라운드로 감(시계로 돌아감·다른 앱). 모두 놓고 "나간다"를 알려 iPhone 이 바로 가상 패드를 되돌리게 한다.
    /// 손목을 내려 화면만 꺼진 것(비활성)은 `releaseAll` 만 — 그때는 iPhone 이 2분 걸쇠로 패드를 숨긴 채 기다린다
    func bye() {
        for t in heartbeats.values { t.invalidate() }
        heartbeats.removeAll()
        send(-1, .bye)
        // 백그라운드로 가는 순간엔 reachable 이 이미 꺼져 sendMessage 가 실패할 수 있다 → applicationContext 로도 (뒤늦게라도 닿는다)
        try? WCSession.default.updateApplicationContext([TeaWire.bye: Date().timeIntervalSince1970])
    }

    /// 진동 (측정 페이지의 스위치). 기본 켬이되 어느 버튼이든 짧은 톡 두 번(.click ×2, 40ms)뿐 — 버튼별로 다른 진동(10차)은 뺐다
    /// (2026-11-10 사용자: 화면을 보면 무엇을 눌렀는지 아니 구분은 필요 없고, 배터리를 위해 최소로; 눌린 느낌은 있어야 하고 .click 은 약함). 크라운 디텐트 톡도 이 스위치를 따른다
    static let hapticsKey = "haptics"
    static var hapticsOn: Bool { UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true }

    private func click(_ b: TeaWire.Button) {
        // 세기는 시스템 종류 중에서만 고를 수 있다. .click 은 약하고 .directionUp 은 세다는 피드백(2026-11-10)
        // → 그 중간: .click 을 40ms 간격으로 두 번. 일시정지(⌂)만 .start 로 구분
        guard Self.hapticsOn else { return }
        let device = WKInterfaceDevice.current()
        if b == .home { device.play(.start); return }
        device.play(.click)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { device.play(.click) }
    }

    private func send(_ button: Int, _ event: TeaWire.Event, done: ((Bool) -> Void)? = nil) {
        let s = WCSession.default
        guard s.activationState == .activated else { done?(false); return }
        seq += 1
        let t = ProcessInfo.processInfo.systemUptime
        s.sendMessage(TeaWire.message(seq: seq, run: run, button: button, event: event, sentAt: t), replyHandler: { [weak self] reply in
            let rtt = ProcessInfo.processInfo.systemUptime - t
            DispatchQueue.main.async {
                guard let self else { return }
                self.rtts.append(rtt)
                if self.rtts.count > 1000 { self.rtts.removeFirst(self.rtts.count - 1000) }
                if (reply[TeaWire.ok] as? Int ?? 1) == 0 { self.rejected += 1 }
                done?(true)
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                self?.errors += 1; self?.lastError = error.localizedDescription
                done?(false)
            }
        })
    }

    // MARK: 측정 (ping N 회, 답장을 받고 다음을 보낸다)

    func measure(count: Int = 200) {
        guard !measuring else { return }
        measuring = true
        rtts.removeAll(); errors = 0; rejected = 0
        var left = count
        func next() {
            guard left > 0 else { measuring = false; return }
            left -= 1
            send(-1, .ping) { _ in next() }
        }
        next()
    }

    struct Stats { let count: Int; let avg: Double; let p50: Double; let p95: Double; let max: Double }
    var stats: Stats? {
        guard !rtts.isEmpty else { return nil }
        let s = rtts.sorted()
        func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
        return Stats(count: s.count, avg: s.reduce(0, +) / Double(s.count), p50: q(0.5), p95: q(0.95), max: s.last!)
    }

    // MARK: 자가 테스트 (시뮬레이터: SIMCTL_CHILD_BINGSU_WATCH_SELFTEST=1). 닿으면 200회 측정 → 버튼 몇 개 → 로그

    func selfTestIfAsked() {
        guard ProcessInfo.processInfo.environment["BINGSU_WATCH_SELFTEST"] == "1" else { return }
        NSLog("[BingsuWatch] 자가 테스트 시작, 닿기를 기다림")
        var waited = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            waited += 1
            if self.reachable { t.invalidate(); self.runSelfTest() }
            else if waited > 120 { t.invalidate(); NSLog("[BingsuWatch] 자가 테스트: 60초 동안 iPhone 에 닿지 않음") }
        }
    }

    private func runSelfTest() {
        // 시뮬레이터의 WC 는 한 번에 2~3초라 30회만 (실기기 측정은 화면의 "200회 측정" 버튼으로)
        NSLog("[BingsuWatch] 닿음. 상태=\(state.rawValue) 게임=\(game) 측정 30회")
        measure(count: 30)
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            ticks += 1
            guard !self.measuring || ticks > 240 else { return }
            t.invalidate()
            if let s = self.stats {
                NSLog("[BingsuWatch] 왕복 n=\(s.count) 평균=\(Int(s.avg * 1000))ms p50=\(Int(s.p50 * 1000))ms p95=\(Int(s.p95 * 1000))ms 최대=\(Int(s.max * 1000))ms 오류=\(self.errors) 버림=\(self.rejected)")
            }
            // 버튼: A 탭 → ▶ 누르고 있기 0.8초 → B 탭 → ⌂(일시정지) → ▼ → B(닫기)
            let steps: [(Double, () -> Void)] = [
                (0.2, { self.tap(.a) }), (0.6, { self.down(.right) }), (1.4, { self.up(.right) }),
                (1.8, { self.tap(.b) }), (2.4, { self.tap(.home) }), (3.4, { self.tap(.down) }), (4.0, { self.tap(.b) }),
                (5.0, { NSLog("[BingsuWatch] 자가 테스트 끝: 보냄=\(self.seq) 오류=\(self.errors) 버림=\(self.rejected) 상태=\(self.state.rawValue)") }),
            ]
            for (d, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) }
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.activated = activationState == .activated
            self.reachable = session.isReachable
            self.apply(session.receivedApplicationContext)
            if let error { self.lastError = error.localizedDescription }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.reachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.apply(applicationContext) }
    }

    private func apply(_ c: [String: Any]) {
        game = c[TeaWire.game] as? String ?? ""
        state = TeaWire.State(rawValue: c[TeaWire.state] as? String ?? "") ?? .home
        enabled = c[TeaWire.enabled] as? Bool ?? true
    }
}
