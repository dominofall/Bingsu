import Foundation
import GameController
import CoreHaptics
import AVFoundation

/// 진동. 실제 컨트롤러(Xbox·PlayStation·일부 MFi)가 있으면 그 모터를, 없으면 폰 자체 햅틱을 CoreHaptics 로 울린다.
/// - `tap`: 홈 초점 이동 때 아주 짧은 톡
/// - `play`: 게임이 Gamepad API `vibrationActuator.playEffect` 로 요청한 진동(세기·길이)
/// 설정 `spoon.rumble` 이 꺼져 있으면 아무것도 하지 않는다.
@MainActor
final class Rumble {
    static let shared = Rumble()
    static let key = "spoon.rumble"

    var enabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: Self.key) == nil ? true : d.bool(forKey: Self.key)
    }

    /// 전체 진동 세기 배율 (설정 슬라이더, 기본 50%: 2026-10-29 "절반 정도로")
    static let strengthKey = "spoon.rumbleStrength"
    var strength: Float {
        let d = UserDefaults.standard
        return d.object(forKey: Self.strengthKey) == nil ? 0.7 : Float(d.double(forKey: Self.strengthKey))
    }

    /// 블루투스 이어폰으로 소리를 들을 때 컨트롤러 진동을 가볍게 (설정, 기본 켬).
    /// 블루투스 컨트롤러 진동 명령과 이어폰 오디오가 폰의 블루투스 무선 하나를 나눠 쓰면서, 진동이 잦으면 이어폰 소리가
    /// 지직거린다 (2026-10-30 iPhone 16 + IINE Retro + 블루투스 이어폰, 진동 끄면 사라짐).
    /// 설정은 진동 켬/끔·세기·블루투스 보호만 남긴다 (2026-10-30 사용자 결정): 효과음 진동은 늘 켬, 작은 모터만 쓰기·최소 세기 조절은 없앰.
    static let btSafeKey = "spoon.rumbleBTSafe"
    var btSafe: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: Self.btSafeKey) == nil ? true : d.bool(forKey: Self.btSafeKey)
    }
    /// 지금 소리가 블루투스로 나가는가 (기기 이름은 보지 않는다)
    static var bluetoothAudio: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType)
        }
    }

    /// 진단 HUD 용: 마지막으로 진동을 보낸 시각과 최근 1초 동안 보낸 횟수
    private(set) var lastFire: Date?
    private var recentFires: [Date] = []
    var firesPerSecond: Int {
        let cut = Date().addingTimeInterval(-1)
        return recentFires.filter { $0 > cut }.count
    }
    /// 블루투스 보호 중 연달아 오는 효과음 진동을 거르는 최소 간격
    private static let btMinGap: TimeInterval = 0.3
    /// 블루투스 보호 중 진동 한 번의 최대 길이
    private static let btMaxDuration: Double = 0.25

    /// 패드마다 엔진 (진동 위치마다 하나: 보통은 `.default` 하나, 실험 모드 `split` 이면 왼손·오른손 둘)
    private var engines: [ObjectIdentifier: [CHHapticEngine]] = [:]
    /// 엔진마다 지금 울리는 플레이어. 새 진동이 오면 앞의 것을 멈춰 겹쳐 울리지 않게 한다 (컨트롤러로 가는 명령 수 줄이기)
    private var players: [ObjectIdentifier: CHHapticPatternPlayer] = [:]
    /// 컨트롤러가 없을 때 쓰는 폰 자체 햅틱 엔진 (가상 패드로 할 때도 같은 패턴을 느끼게)
    private var phoneEngine: CHHapticEngine?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in if let c = n.object as? GCController { self?.drop(c) } }
        })
    }

    /// 연결된 패드마다 엔진을 하나씩 (필요할 때 만들고, 끊기면 버린다)
    /// 호스트가 보내는 세기 값을 비례로 받는 패드인가. IINE Retro 는 DualShock·Xbox·스위치 모드 모두 켜짐/꺼짐만 받아
    /// (스위치 모드에서는 패드 자체 전역 단계만 적용, 2026-10-30 진동 실험실로 재확인) 펄스는 지금 꺼 둠(`usePulse`).
    /// 그래서 서드파티 패드의 크기 조절은 패드 자체 단계에 맡기고, 앱은 최소 길이만 보장한다.
    static func honorsIntensity(_ c: GCController) -> Bool { false }

    private func activeEngines() -> [(engine: CHHapticEngine, controller: Bool)] {
        var out: [(engine: CHHapticEngine, controller: Bool)] = []
        for c in GCController.controllers() where c.extendedGamepad != nil && !c.isSnapshot {
            let id = ObjectIdentifier(c)
            if let es = engines[id] { out += es.map { ($0, !Self.honorsIntensity(c)) }; continue }
            guard let h = c.haptics else { continue }
            let made: [CHHapticEngine] = Self.localities(for: h).compactMap { loc in
                guard let e = h.createEngine(withLocality: loc) else { return nil }
                e.playsHapticsOnly = true
                // 쉬는 동안엔 엔진이 패드와 통신하지 않게 (블루투스 대역을 비워 둔다)
                e.isAutoShutdownEnabled = true
                e.resetHandler = { [weak e] in try? e?.start() }
                return (try? e.start()) != nil ? e : nil
            }
            if Self.debug {
                let locs = h.supportedLocalities.map(\.rawValue).sorted().joined(separator: ",")
                NSLog("[Rumble] 패드 \(c.vendorName ?? "?") · \(c.productCategory) · 위치 [\(locs)] → 엔진 \(made.count)개 (\(Self.localityMode))")
            }
            guard !made.isEmpty else { continue }
            engines[id] = made
            out += made.map { ($0, !Self.honorsIntensity(c)) }   // 진폭을 받는 패드는 폰 햅틱처럼 세기 값 그대로
        }
        if out.isEmpty, CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            if phoneEngine == nil, let e = try? CHHapticEngine() {
                e.playsHapticsOnly = true
                e.resetHandler = { [weak e] in try? e?.start() }
                phoneEngine = e
            }
            if let e = phoneEngine, (try? e.start()) != nil { out.append((e, false)) }
        }
        return out
    }

    private func drop(_ c: GCController) {
        let id = ObjectIdentifier(c)
        for e in engines[id] ?? [] { players[ObjectIdentifier(e)] = nil; e.stop(completionHandler: nil) }
        engines[id] = nil
    }

    /// 진동 위치 실험 (개발용 `BINGSU_RUMBLE_LOCALITY`): `default`(기본) · `handles`(양손 묶음) · `split`(왼손·오른손 엔진 따로).
    /// 스위치 모드 IINE 가 "가장 세게 해도 약하다" → `.default` 가 모터 하나만 돌리는지 가리려고 (2026-10-30)
    static let localityMode = ProcessInfo.processInfo.environment["BINGSU_RUMBLE_LOCALITY"] ?? "default"
    private static func localities(for h: GCDeviceHaptics) -> [GCHapticsLocality] {
        let has = h.supportedLocalities
        switch localityMode {
        case "handles" where has.contains(.handles): return [.handles]
        case "split" where has.contains(.leftHandle) && has.contains(.rightHandle): return [.leftHandle, .rightHandle]
        default: return [.default]
        }
    }

    /// 아주 짧은 톡 (홈에서 초점이 옮겨질 때). 게임 버튼 누름에는 쓰지 않는다 (2026-10-29 사용자 결정)
    func tap(intensity: Float) {
        guard enabled else { return }
        let ev = CHHapticEvent(eventType: .hapticTransient,
                               parameters: [.init(parameterID: .hapticIntensity, value: intensity * strength),
                                            .init(parameterID: .hapticSharpness, value: 0.25)],
                               relativeTime: 0)
        fire { _, _ in [ev] }
    }

    /// 컨트롤러 진동을 짧은 펄스로 쪼개 켜짐 비율로 세기를 만들지. IINE Retro 등은 세기 값이 일정 아래면 안 울리고 그 위는 거의 같아서
    /// 켜짐 비율로 조절하려 했지만, 효과음 진동은 0.1~0.3초라 펄스 하나가 모터가 돌기도 전에 꺼져 "윙" 소리만 나고 손에 안 느껴졌다
    /// (2026-10-30 iPhone 16 + IINE, 진동 실험실). 그래서 꺼 두고 한 덩어리로 보낸다. 폰 햅틱(Taptic)은 원래 펄스를 쓰지 않는다.
    static let usePulse = false

    /// 컨트롤러 모터 데드존: 이 값 아래 세기는 모터가 돌지 않아 조용하다 (ERM 모터 특성).
    /// 펄스를 쓰지 않을 때 앱의 세기 0...1 을 [floor, 1] 로 다시 매핑한다.
    private static let controllerFloor: Float = 0.4

    /// 컨트롤러 진동 최소 길이(초). 0.1초 남짓한 진동은 패드 모터가 제 속도까지 돌기 전에 끝나 거의 안 느껴진다
    /// (2026-10-30 IINE 스위치 모드: 최대 세기도 약함 → 세기는 더 못 올리니 짧은 진동만 늘린다). 정품 패드엔 거의 티가 안 남.
    /// 개발용 `BINGSU_RUMBLE_MINLEN` 으로 바꿔 비교 (0.05~0.4)
    static let controllerMinLength: Double = {
        if let v = ProcessInfo.processInfo.environment["BINGSU_RUMBLE_MINLEN"].flatMap(Double.init), v.isFinite { return min(max(v, 0.05), 0.4) }
        return 0.2   // 2026-10-30 IINE 스위치 모드에서 0.2초면 짧은 진동도 잘 느껴짐 (사용자 확인)
    }()

    /// 게임이 요청한 진동. strong/weak 0...1, duration 초. 길이 0 이면 멈춤.
    func play(strong: Float, weak: Float, duration: TimeInterval) {
        guard enabled else { return }
        let d = min(max(duration, 0), 5)
        let base = min(1, max(strong, weak * 0.6))
        guard d > 0, base > 0.01 else { stopAll(); return }
        fire { self.emit(intensity: base, sharpness: strong >= weak ? 0.2 : 0.7, at: 0, duration: d, controller: $0, pulse: $1) }
    }

    /// 효과음 진동표의 패턴. 반복이 있으면 간격을 두고 이어 울린다.
    func play(_ p: RumbleSet.Pattern) {
        guard enabled else { return }
        let light = lightForBluetooth
        // 블루투스 보호: 바로 앞 진동과 너무 가까우면 건너뛴다 (피격 연타·볼 흔들림 반복)
        if light, let last = lastFire, Date().timeIntervalSince(last) < Self.btMinGap { return }
        fire { controller, pulse in
            var events: [CHHapticEvent] = []
            var t = 0.0
            for _ in 0..<(light && controller ? 1 : max(1, p.repeats)) {
                events += self.emit(intensity: min(1, max(p.strong, p.weak * 0.6)), sharpness: p.sharpness ?? (p.strong >= p.weak ? 0.2 : 0.7),
                                    at: t, duration: min(max(p.duration, 0.02), 2), controller: controller, pulse: pulse)
                t += p.duration + p.gap
            }
            return events
        }
    }

    /// 설정의 세기 슬라이더를 움직일 때: 같은 길이로 주어진 세기만 울린다 (전체 배율은 똑같이 적용)
    func test(intensity: Float, sharpness: Float = 0.3, duration: Double = 0.8) {
        guard enabled else { return }
        fire { self.emit(intensity: intensity, sharpness: sharpness, at: 0, duration: duration, controller: $0, pulse: $1) }
    }

    /// 세기 배율을 한 번만 곱해 이벤트로 만든다. 컨트롤러면 데드존 위로 재매핑, `pulse` 면 40ms 주기로 켜짐 비율 = 세기.
    private func emit(intensity raw: Float, sharpness: Float, at t: Double, duration d0: Double, controller: Bool, pulse: Bool) -> [CHHapticEvent] {
        var i = min(1, max(0, raw * strength))
        guard i > 0.005 else { return [] }
        // 블루투스 보호 중 컨트롤러: 펄스 대신 한 덩어리로 보내므로, 세기 배율만큼 길이를 줄여 약하게 느끼게 한다
        let d1 = controller && lightForBluetooth ? max(0.04, min(d0 * (0.4 + 0.6 * Double(strength)), Self.btMaxDuration)) : d0
        let d = controller ? max(d1, Self.controllerMinLength) : d1
        if controller && !pulse { i = Self.controllerFloor + (1 - Self.controllerFloor) * i }   // 데드존 위로
        if !pulse || i > 0.95 {
            return [CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [.init(parameterID: .hapticIntensity, value: i),
                                               .init(parameterID: .hapticSharpness, value: sharpness)],
                                  relativeTime: t, duration: d)]
        }
        // 켜짐/꺼짐만 되는 패드는 전압을 못 낮추므로, 켜진 비율과 함께 진동 길이도 줄여 손에 닿는 양을 줄인다 (100% → 그대로, 10% → 46%)
        let shorter = d * (0.4 + 0.6 * Double(strength))
        return pulses(intensity: i, sharpness: sharpness, at: t, duration: max(0.02, shorter))
    }

    /// 켜짐/꺼짐만 받는 모터용 PWM. 모터가 제 속도까지 돌 시간을 주려고 주기 100ms, 켜짐 비율은 40%를 바닥으로
    /// (세기 0 → 40%, 1 → 100%). 너무 짧은 펄스는 모터가 돌기도 전에 꺼져 약하게만 느껴진다 (2026-10-29 실기기).
    private func pulses(intensity i: Float, sharpness: Float, at t: Double, duration d: Double) -> [CHHapticEvent] {
        let period = 0.1, duty = 0.4 + 0.6 * Double(i), on = max(0.03, period * duty)
        var out: [CHHapticEvent] = []
        var x = 0.0
        while x < d {
            out.append(CHHapticEvent(eventType: .hapticContinuous,
                                     parameters: [.init(parameterID: .hapticIntensity, value: 1),
                                                  .init(parameterID: .hapticSharpness, value: sharpness)],
                                     relativeTime: t + x, duration: min(on, d - x)))
            x += period
        }
        return out
    }

    /// 울리는 진동만 멈춘다. 엔진은 그대로 둬서(쉬면 스스로 꺼짐) 다음 진동 때 다시 만들고 시작하는 비용·통신을 없앤다
    func stopAll() {
        for p in players.values { try? p.stop(atTime: CHHapticTimeImmediate) }
        players.removeAll()
    }

    /// 블루투스 이어폰 + 설정 켬: 컨트롤러 진동을 펄스 없이 한 덩어리로, 짧게, 드물게 보낸다
    private var lightForBluetooth: Bool { btSafe && Self.bluetoothAudio }

    private static let debug = ProcessInfo.processInfo.environment["BINGSU_KEYDEBUG"] == "1"

    /// 엔진마다 이벤트를 만든다: 컨트롤러는 `usePulse` 면 펄스(블루투스 보호 중엔 끔), 폰 햅틱은 세기 값 그대로
    private func fire(_ make: (_ controller: Bool, _ pulse: Bool) -> [CHHapticEvent]) {
        let light = lightForBluetooth
        var sent = false
        for (e, isController) in activeEngines() {
            let events = make(isController, isController && Self.usePulse && !light)
            guard !events.isEmpty, let pattern = try? CHHapticPattern(events: events, parameters: []),
                  let player = try? e.makePlayer(with: pattern) else { continue }
            let key = ObjectIdentifier(e)
            if let old = players[key] { try? old.stop(atTime: CHHapticTimeImmediate) }
            players[key] = player
            try? player.start(atTime: CHHapticTimeImmediate)
            sent = true
            if Self.debug {
                let on = events.reduce(0.0) { $0 + $1.duration }, end = events.map { $0.relativeTime + $0.duration }.max() ?? 0
                let lv = events.first?.eventParameters.first { $0.parameterID == .hapticIntensity }?.value ?? 0
                let sh = events.first?.eventParameters.first { $0.parameterID == .hapticSharpness }?.value ?? 0
                NSLog("[Rumble] -> \(isController ? "컨트롤러" : "폰") 이벤트 \(events.count)개 켜짐 \(Int(on * 1000))ms / \(Int(end * 1000))ms 세기 \(String(format: "%.2f", lv)) 날카로움 \(String(format: "%.2f", sh))\(light ? " 블루투스 보호" : "")")
            }
        }
        if !sent && Self.debug { NSLog("[Rumble] 보낼 곳 없음 (컨트롤러 엔진·폰 햅틱 모두 없음)") }
        if sent {
            let now = Date()
            lastFire = now
            recentFires.append(now)
            recentFires.removeAll { now.timeIntervalSince($0) > 1 }
        }
    }
}
