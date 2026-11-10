import Foundation
import Combine
import MultipeerConnectivity
import UIKit

/// 큰숟가락: iPhone 을 iPad 의 컨트롤러로 (docs/iphone-pad/CONDITIONS.md). 워치(TeaSpoon)와 같은 `TeaWire` 형식을
/// MultipeerConnectivity(같은 Wi-Fi·블루투스 범위, 암호화 필수)로 보낸다. iPad 가 광고하고(`TableSpoonLink`) iPhone 이 찾아 초대한다(`TableSpoonRemote`).
/// 입력만 보내고 화면은 보내지 않는다. 받는 쪽은 워치와 같은 `TeaSpoon` 이라 게임 화면 쪽 변경이 없다.
enum TableSpoon {
    /// Bonjour 서비스 이름 (Info.plist `NSBonjourServices` 의 `_bingsu-pad._tcp/_udp` 와 같아야 한다)
    static let serviceType = "bingsu-pad"
    /// 이 기기의 peer. 앱이 켜져 있는 동안 하나 (iOS 16+ 에서 기기 이름은 "iPhone"·"iPad" 처럼 일반 이름으로 나온다)
    static let me = MCPeerID(displayName: UIDevice.current.name)
    /// 받는 쪽이 될 수 있는 기기: iPad. 개발용 `BINGSU_TABLESPOON_HOST=1` 이면 iPhone(시뮬레이터)도 받아 시뮬레이터 둘로 확인한다
    static var canHost: Bool { UIDevice.current.userInterfaceIdiom == .pad || DevEnv["BINGSU_TABLESPOON_HOST"] == "1" }
    /// 보내는 쪽이 될 수 있는 기기: iPhone
    static var canRemote: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    /// 개발용 `BINGSU_TABLESPOON_LOOPBACK=1`: 시뮬레이터 하나 안에서 보내는 쪽 → 받는 쪽으로 바로 넘긴다 (바이트 인코딩은 거친다).
    /// 시뮬레이터 둘 사이의 MultipeerConnectivity 는 찾기까지만 되고 초대가 닿지 않아서(2026-11-09 확인) 연결 자체는 실기기로 본다
    static var loopback: Bool { DevEnv["BINGSU_TABLESPOON_LOOPBACK"] == "1" }
}

// MARK: - iPad: 받는 쪽

/// iPad 에서 하나. 앱 시작 때 `start()`. 설정 "iPhone 을 컨트롤러로"(기본 켬)가 켜져 있으면 광고하고, 초대가 오면 `invite` 로 화면에 묻는다.
/// 델리게이트는 백그라운드 큐에서 오므로 메인으로 넘긴다 (TeaSpoonLink 와 같은 방식).
final class TableSpoonLink: NSObject, ObservableObject {
    static let shared = TableSpoonLink()
    static let enabledKey = "bingsu.tableSpoon"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// 초대 하나. `accept` 는 한 번만 답한다 (알림이 닫히며 또 불려도 안전)
    final class Invite: Identifiable {
        let id = UUID()
        let name: String
        private var handler: ((Bool) -> Void)?
        init(name: String, handler: @escaping (Bool) -> Void) { self.name = name; self.handler = handler }
        func accept(_ ok: Bool) { handler?(ok); handler = nil }
    }

    @Published private(set) var connectedName: String?
    @Published var invite: Invite?
    @Published private(set) var advertising = false
    @Published private(set) var received = 0
    @Published private(set) var lastInputAt: Date?
    var connected: Bool { connectedName != nil }

    /// 지금 입력을 받을 게임 화면 (없으면 버린다)
    @MainActor weak var target: TeaSpoon?

    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var peer: MCPeerID?
    private var lastSeq = -1
    private var context: [String: Any] = [:]

    func start() {
        guard TableSpoon.canHost else { return }
        refresh()
    }

    /// 설정이 바뀌었을 때도 부른다: 켜져 있으면 광고, 꺼지면 광고를 멈추고 연결을 끊는다
    func refresh() {
        guard TableSpoon.canHost else { return }
        if Self.isEnabled {
            if session == nil {
                let s = MCSession(peer: TableSpoon.me, securityIdentity: nil, encryptionPreference: .required)
                s.delegate = self
                session = s
            }
            if advertiser == nil {
                let a = MCNearbyServiceAdvertiser(peer: TableSpoon.me, discoveryInfo: nil, serviceType: TableSpoon.serviceType)
                a.delegate = self
                a.startAdvertisingPeer()
                advertiser = a
                advertising = true
            }
        } else {
            advertiser?.stopAdvertisingPeer(); advertiser = nil; advertising = false
            session?.disconnect()
            invite?.accept(false); invite = nil
        }
    }

    /// 설정 화면 문구
    var statusLabel: String {
        if !Self.isEnabled { return "꺼짐" }
        if let n = connectedName { return "\(n) 연결됨" }
        return advertising ? "iPhone 에서 ‘iPad 컨트롤러’를 열면 연결돼요" : "준비 중"
    }

    /// 게임 이름·상태 (TeaSpoonLink.setContext 가 같이 부른다). 바뀐 값만 보낸다
    func setContext(game: String, state: TeaWire.State) {
        let next: [String: Any] = [TeaWire.event: TeaWire.Event.context.rawValue, TeaWire.game: game,
                                   TeaWire.state: state.rawValue, TeaWire.enabled: Self.isEnabled]
        if let old = context as? [String: AnyHashable], let new = next as? [String: AnyHashable], old == new { return }
        context = next
        send(next)
    }

    /// 게임 진동을 연결된 iPhone 으로. 보냈으면 true (iPad 자체는 진동이 없다)
    @discardableResult
    func forwardRumble(strong: Float, weak: Float, duration: Double, sharpness: Float?, repeats: Int, gap: Double) -> Bool {
        guard connected else { return false }
        var m: [String: Any] = [TeaWire.event: TeaWire.Event.rumble.rawValue, TeaWire.strong: strong, TeaWire.weak: weak,
                                TeaWire.duration: duration, TeaWire.repeats: repeats, TeaWire.gap: gap]
        if let sharpness { m[TeaWire.sharpness] = sharpness }
        send(m)
        return true
    }

    private func send(_ m: [String: Any], reliable: Bool = true) {
        guard let d = TeaWire.encode(m) else { return }
        if TableSpoon.loopback, connected {
            if let mm = TeaWire.decode(d) { DispatchQueue.main.async { TableSpoonRemote.shared.loopbackReceive(mm) } }
            return
        }
        guard let s = session, let p = peer, s.connectedPeers.contains(p) else { return }
        do { try s.send(d, toPeers: [p], with: reliable ? .reliable : .unreliable) }
        catch { NSLog("[TableSpoon] 보내기 실패: \(error.localizedDescription)") }
    }

    /// 개발용 loopback: 보내는 쪽이 붙었다/떨어졌다, 메시지가 왔다
    func loopbackConnect(_ on: Bool) {
        connectedName = on ? TableSpoon.me.displayName : nil
        if on { lastSeq = -1; let c = context; context = [:]; setContext(game: c[TeaWire.game] as? String ?? "", state: TeaWire.State(rawValue: c[TeaWire.state] as? String ?? "") ?? .home) }
        else { _ = MainActor.assumeIsolated { target?.handle(button: -1, event: .releaseAll) } }
    }
    func loopbackReceive(_ m: [String: Any]) { dispatch(m, from: TableSpoon.me) }

    /// 메인에서. 답장은 ping 에만 (왕복 시간 측정)
    private func dispatch(_ m: [String: Any], from p: MCPeerID) {
        guard let raw = m[TeaWire.event] as? Int, let event = TeaWire.Event(rawValue: raw) else { return }
        if event == .ping {
            var reply = m; reply[TeaWire.ok] = 1
            send(reply, reliable: false)
            return
        }
        guard Self.isEnabled, event.rawValue <= TeaWire.Event.releaseAll.rawValue || event == .stick else { return }
        let seq = m[TeaWire.seq] as? Int ?? 0
        // 역순·중복은 버린다 (iPhone 쪽이 다시 켜지면 0 부터라 크게 뒤로 가면 받아 준다)
        if seq <= lastSeq && lastSeq - seq < 1000 { return }
        lastSeq = seq
        received += 1; lastInputAt = Date()
        if event == .stick {
            let l = CGVector(dx: m[TeaWire.lx] as? Double ?? 0, dy: m[TeaWire.ly] as? Double ?? 0)
            let r = CGVector(dx: m[TeaWire.rx] as? Double ?? 0, dy: m[TeaWire.ry] as? Double ?? 0)
            MainActor.assumeIsolated { target?.handleStick(left: l, right: r) }
            return
        }
        let button = m[TeaWire.button] as? Int ?? -1
        _ = MainActor.assumeIsolated { target?.handle(button: button, event: event) }
    }
}

extension TableSpoonLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            guard Self.isEnabled, let s = self.session else { invitationHandler(false, nil); return }
            // 이미 다른 iPhone 이 붙어 있으면 거절. 같은 iPhone 이 다시 오면(끊겼다 재연결) 바로 받는다
            if let cur = self.peer, s.connectedPeers.contains(cur) {
                invitationHandler(cur == peerID, cur == peerID ? s : nil); return
            }
            // 개발용: 시뮬레이터 둘로 확인할 때 물음 없이 받는다
            if DevEnv["BINGSU_TABLESPOON_AUTOACCEPT"] == "1" { self.peer = peerID; invitationHandler(true, s); return }
            self.invite?.accept(false)
            self.invite = Invite(name: peerID.displayName) { ok in
                if ok { self.peer = peerID }
                invitationHandler(ok, ok ? s : nil)
            }
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("[TableSpoon] 광고 실패: \(error.localizedDescription)")
        DispatchQueue.main.async { self.advertising = false }
    }
}

extension TableSpoonLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.peer = peerID
                self.connectedName = peerID.displayName
                self.lastSeq = -1
                let c = self.context; self.context = [:]
                if !c.isEmpty { self.setContext(game: c[TeaWire.game] as? String ?? "", state: TeaWire.State(rawValue: c[TeaWire.state] as? String ?? "") ?? .home) }
                else { self.setContext(game: "", state: .home) }
            case .notConnected:
                if self.peer == peerID {
                    self.connectedName = nil
                    _ = MainActor.assumeIsolated { self.target?.handle(button: -1, event: .releaseAll) }
                }
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let m = TeaWire.decode(data) else { return }
        DispatchQueue.main.async { self.dispatch(m, from: peerID) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - iPhone: 보내는 쪽

/// iPhone 컨트롤러 화면(`TableSpoonView`)이 쓴다. 찾기 → 초대 → 연결 → 버튼 보내기. 워치 `WatchLink` 와 같은 tap/down/up/하트비트.
final class TableSpoonRemote: NSObject, ObservableObject {
    static let shared = TableSpoonRemote()

    @Published private(set) var found: [MCPeerID] = []
    @Published private(set) var connected: MCPeerID?
    @Published private(set) var connecting: MCPeerID?
    @Published private(set) var game = ""
    @Published private(set) var state: TeaWire.State = .home
    @Published private(set) var hostEnabled = true
    @Published private(set) var rtts: [Double] = []
    @Published private(set) var lastError = ""
    @Published private(set) var measuring = false
    @Published private(set) var browsing = false

    /// 지금 눌러도 되는가 (iPad 가 게임 화면이어야 한다)
    var canPlay: Bool { connected != nil && hostEnabled && state != .home }

    private var session: MCSession?
    private var browser: MCNearbyServiceBrowser?
    private var seq = 0
    private var heartbeats: [Int: Timer] = [:]
    /// 스틱: 지금 값, 마지막으로 보낸 값·시각, 30Hz 타이머 (기울어 있는 동안만 돈다)
    private var stickNow = (l: CGVector.zero, r: CGVector.zero)
    private var stickSent = (l: CGVector.zero, r: CGVector.zero)
    private var stickSentAt = Date.distantPast
    private var stickTimer: Timer?
    private var measureTimer: Timer?
    private var measureLeft = 0
    private var wantBrowsing = false

    // MARK: 연결

    func startBrowsing() {
        guard TableSpoon.canRemote else { return }
        if TableSpoon.loopback { found = [TableSpoon.me]; browsing = true; return }
        wantBrowsing = true
        if browser == nil {
            let b = MCNearbyServiceBrowser(peer: TableSpoon.me, serviceType: TableSpoon.serviceType)
            b.delegate = self
            b.startBrowsingForPeers()
            browser = b
            browsing = true
        }
    }

    func stopBrowsing() {
        wantBrowsing = false
        browser?.stopBrowsingForPeers(); browser = nil; browsing = false
        found.removeAll()
    }

    func connect(_ peer: MCPeerID) {
        if session == nil {
            let s = MCSession(peer: TableSpoon.me, securityIdentity: nil, encryptionPreference: .required)
            s.delegate = self
            session = s
        }
        guard let s = session else { return }
        lastError = ""
        if TableSpoon.loopback { connected = peer; TableSpoonLink.shared.loopbackConnect(true); return }
        connecting = peer
        browser?.invitePeer(peer, to: s, withContext: nil, timeout: 20)
    }

    func disconnect() {
        releaseAll()
        if TableSpoon.loopback { TableSpoonLink.shared.loopbackConnect(false) }
        session?.disconnect()
        connected = nil; connecting = nil
    }

    /// 개발용 loopback: 받는 쪽이 보낸 메시지
    func loopbackReceive(_ m: [String: Any]) { receive(m) }

    var statusLabel: String {
        guard let c = connected else { return connecting != nil ? "연결하는 중…" : "iPad 를 찾는 중" }
        if !hostEnabled { return "\(c.displayName) 의 설정 › 컨트롤러에서\n‘iPhone 을 컨트롤러로’를 켜 주세요" }
        switch state {
        case .home: return "\(c.displayName) 에서\n게임을 시작하면 조작할 수 있어요"
        case .playing: return game
        case .paused: return "일시정지"
        }
    }

    // MARK: 보내기

    func tap(_ b: PadButton) { send(b.rawValue, .tap) }

    func down(_ b: PadButton) {
        send(b.rawValue, .down)
        heartbeats[b.rawValue]?.invalidate()
        heartbeats[b.rawValue] = Timer.scheduledTimer(withTimeInterval: TeaWire.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.send(b.rawValue, .heartbeat, reliable: false)
        }
    }

    func up(_ b: PadButton) {
        heartbeats[b.rawValue]?.invalidate(); heartbeats[b.rawValue] = nil
        send(b.rawValue, .up)
    }

    func releaseAll() {
        for t in heartbeats.values { t.invalidate() }
        heartbeats.removeAll()
        stickTimer?.invalidate(); stickTimer = nil
        stickNow = (.zero, .zero); stickSent = (.zero, .zero)
        send(-1, .releaseAll)
    }

    /// 스틱 값 (-1…1). 바로 보내지 않고 30Hz 로 모아 보낸다: 바뀌었을 때, 기울어 있으면 0.3초마다 한 번은 (iPad 쪽 끊김 판정용)
    func setStick(right: Bool, vector: CGVector) {
        if right { stickNow.r = vector } else { stickNow.l = vector }
        if stickTimer == nil {
            stickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.flushStick() }
            flushStick()
        }
    }

    private func flushStick() {
        func q(_ v: CGVector) -> CGVector { CGVector(dx: (v.dx * 50).rounded() / 50, dy: (v.dy * 50).rounded() / 50) }
        let l = q(stickNow.l), r = q(stickNow.r)
        let changed = l != stickSent.l || r != stickSent.r
        let idle = l == .zero && r == .zero
        if changed || (!idle && Date().timeIntervalSince(stickSentAt) >= TeaWire.heartbeatInterval) {
            guard let p = connected else { return }
            seq += 1
            var m = TeaWire.message(seq: seq, button: -1, event: .stick, sentAt: ProcessInfo.processInfo.systemUptime)
            m[TeaWire.lx] = l.dx; m[TeaWire.ly] = l.dy; m[TeaWire.rx] = r.dx; m[TeaWire.ry] = r.dy
            sendRaw(m, to: p, reliable: idle)   // 가운데로 돌아오는 것만은 확실히
            stickSent = (l, r); stickSentAt = Date()
        }
        if idle && stickSent.l == .zero && stickSent.r == .zero { stickTimer?.invalidate(); stickTimer = nil }
    }

    /// 왕복 시간 측정: 50ms 간격으로 ping 을 보내고 답장으로 잰다 (입력 아님)
    func measure(count: Int = 100) {
        guard connected != nil, !measuring else { return }
        measuring = true; measureLeft = count; rtts.removeAll()
        measureTimer?.invalidate()
        measureTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.measureLeft <= 0 || self.connected == nil {
                t.invalidate(); self.measureTimer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.measuring = false }
                return
            }
            self.measureLeft -= 1
            self.send(-1, .ping, reliable: false)
        }
    }

    var stats: (count: Int, avg: Double, p50: Double, p95: Double, max: Double)? {
        guard !rtts.isEmpty else { return nil }
        let s = rtts.sorted()
        func pct(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
        return (s.count, s.reduce(0, +) / Double(s.count), pct(0.5), pct(0.95), s.last!)
    }

    private func send(_ button: Int, _ event: TeaWire.Event, reliable: Bool = true) {
        guard let p = connected else { return }
        seq += 1
        sendRaw(TeaWire.message(seq: seq, button: button, event: event, sentAt: ProcessInfo.processInfo.systemUptime), to: p, reliable: reliable)
    }

    private func sendRaw(_ m: [String: Any], to p: MCPeerID, reliable: Bool) {
        guard let d = TeaWire.encode(m) else { return }
        if TableSpoon.loopback {
            if let mm = TeaWire.decode(d) { DispatchQueue.main.async { TableSpoonLink.shared.loopbackReceive(mm) } }
            return
        }
        guard let s = session, s.connectedPeers.contains(p) else { return }
        do { try s.send(d, toPeers: [p], with: reliable ? .reliable : .unreliable) }
        catch { lastError = error.localizedDescription }
    }

    /// 메인에서. iPad 가 보내는 것: ping 답장, 게임 상태, 진동
    private func receive(_ m: [String: Any]) {
        guard let raw = m[TeaWire.event] as? Int, let event = TeaWire.Event(rawValue: raw) else { return }
        switch event {
        case .ping:
            guard m[TeaWire.ok] != nil, let t = m[TeaWire.sentAt] as? Double else { return }
            rtts.append(ProcessInfo.processInfo.systemUptime - t)
            if rtts.count > 500 { rtts.removeFirst(rtts.count - 500) }
        case .context:
            game = m[TeaWire.game] as? String ?? ""
            state = TeaWire.State(rawValue: m[TeaWire.state] as? String ?? "") ?? .home
            hostEnabled = m[TeaWire.enabled] as? Bool ?? true
        case .rumble:
            let p = RumbleSet.Pattern(strong: Float(m[TeaWire.strong] as? Double ?? 0), weak: Float(m[TeaWire.weak] as? Double ?? 0),
                                      duration: m[TeaWire.duration] as? Double ?? 0, repeats: m[TeaWire.repeats] as? Int ?? 1,
                                      gap: m[TeaWire.gap] as? Double ?? 0, sharpness: (m[TeaWire.sharpness] as? Double).map(Float.init))
            MainActor.assumeIsolated { Rumble.shared.play(p) }
        default: break
        }
    }
}

extension TableSpoonRemote: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { if !self.found.contains(peerID) { self.found.append(peerID) } }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.found.removeAll { $0 == peerID } }
    }
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription; self.browsing = false }
    }
}

extension TableSpoonRemote: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.connected = peerID; self.connecting = nil
                self.rtts.removeAll()
                // 붙어 있는 동안은 찾기를 멈춘다 (무선 아낌). 끊기면 다시 찾는다
                self.browser?.stopBrowsingForPeers(); self.browser = nil; self.browsing = false
            case .notConnected:
                if self.connecting == peerID { self.connecting = nil; self.lastError = "연결되지 않았어요. iPad 에서 ‘연결’을 눌렀는지 확인해 주세요" }
                if self.connected == peerID {
                    self.connected = nil
                    for t in self.heartbeats.values { t.invalidate() }
                    self.heartbeats.removeAll()
                }
                if self.wantBrowsing && self.browser == nil { self.wantBrowsing = false; self.startBrowsing() }
            case .connecting:
                self.connecting = peerID
            @unknown default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let m = TeaWire.decode(data) else { return }
        DispatchQueue.main.async { self.receive(m) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
