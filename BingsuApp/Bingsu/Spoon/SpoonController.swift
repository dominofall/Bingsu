import Foundation
import Combine
import CoreGraphics
import UIKit
import WebKit

/// 가상 패드 상태를 모아 게임에 보낸다.
/// - gamepad: `__bingsu.pad(mask, lx, ly, rx, ry, lt, rt)` → 웹뷰 안의 가상 Gamepad 객체 갱신
/// - keyboard: 버튼·스틱 방향을 KeyboardEvent 로 합성
@MainActor
final class SpoonController: ObservableObject {
    struct StickState: Equatable {
        var active = false
        var base = CGPoint.zero
        var knob = CGPoint.zero
        var vector = CGVector.zero   // -1...1
    }

    @Published private(set) var pressed: Set<PadButton> = []
    @Published private(set) var leftStick = StickState()
    @Published private(set) var rightStick = StickState()
    @Published var mode: CutlerySet.Mode = .field
    /// 떠다니는 십자키가 생긴 자리 (`SpoonLayout.dpadZone`). 손을 떼면 nil. 그리는 쪽이 십자키를 여기로 옮겨 그린다
    @Published var dpadFloatCenter: CGPoint?

    var cutlery: CutlerySet = .keyboardDefault
    weak var webView: WKWebView?
    /// 웹뷰가 아닌 게임(RPG Maker XP, BrassBowl)은 키를 여기로 받는다 (KeyboardEvent.code, 눌림)
    var keySink: ((String, Bool) -> Void)?
    var hapticsEnabled = true
    var eightWay = false

    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var keyboardHeld: Set<String> = []
    private var lastSent = ""

    // MARK: 입력 (터치 뷰에서 호출)

    func press(_ b: PadButton, haptic useHaptic: Bool = true) {
        pendingRelease[b]?.cancel(); pendingRelease[b] = nil
        guard !pressed.contains(b) else { return }
        buttonDownAt[b] = Date()
        pressed.insert(b)
        if hapticsEnabled && useHaptic { haptic.impactOccurred(intensity: 0.6) }
        sync()
    }

    /// 실제 컨트롤러 스틱 (화면 좌표 없이 벡터만)
    func setStick(right: Bool, vector: CGVector) {
        var v = vector
        if hypot(v.dx, v.dy) < 0.12 { v = .zero }   // 데드존
        var s = right ? rightStick : leftStick
        guard s.vector != v else { return }
        s.active = v != .zero; s.vector = v
        if right { rightStick = s } else { leftStick = s }
        sync()
    }

    func release(_ b: PadButton, immediate: Bool = false) {
        guard pressed.contains(b) else { return }
        if immediate { finishRelease(b); return }
        // 게임은 프레임 단위로 패드를 읽으므로 너무 짧은 누름은 최소 시간만큼 붙잡아 둔다
        let elapsed = Date().timeIntervalSince(buttonDownAt[b] ?? .distantPast)
        if elapsed < minPress {
            pendingRelease[b]?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.pendingRelease[b] = nil; self?.finishRelease(b) }
            pendingRelease[b] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (minPress - elapsed), execute: work)
            return
        }
        finishRelease(b)
    }

    private func finishRelease(_ b: PadButton) {
        guard pressed.remove(b) != nil else { return }
        sync()
    }
    private var buttonDownAt: [PadButton: Date] = [:]
    private var pendingRelease: [PadButton: DispatchWorkItem] = [:]

    func stickBegan(right: Bool, at p: CGPoint, slot: StickSlot) {
        var s = right ? rightStick : leftStick
        s.active = true
        s.base = slot.floating ? p : slot.restCenter
        s.knob = s.base
        s.vector = .zero
        if right { rightStick = s } else { leftStick = s }
        sync()
    }

    func stickMoved(right: Bool, to p: CGPoint, slot: StickSlot) {
        var s = right ? rightStick : leftStick
        guard s.active else { return }
        var dx = p.x - s.base.x, dy = p.y - s.base.y
        let d = hypot(dx, dy)
        if d > slot.travel { dx *= slot.travel / d; dy *= slot.travel / d }
        s.knob = CGPoint(x: s.base.x + dx, y: s.base.y + dy)
        s.vector = CGVector(dx: dx / slot.travel, dy: dy / slot.travel)
        if right { rightStick = s } else { leftStick = s }
        sync()
    }

    func stickEnded(right: Bool) {
        var s = right ? rightStick : leftStick
        s.active = false; s.vector = .zero
        if right { rightStick = s } else { leftStick = s }
        sync()
    }

    func releaseAll() {
        for w in pendingRelease.values { w.cancel() }
        pendingRelease.removeAll()
        pressed.removeAll()
        leftStick = StickState(); rightStick = StickState()
        sync()
    }

    // MARK: 전송

    private func sync() {
        switch cutlery.transport {
        case .gamepad: sendGamepad()
        case .keyboard: sendKeyboard()
        }
    }

    private func sendGamepad() {
        var mask: UInt32 = 0
        for b in pressed { mask |= 1 << UInt32(b.rawValue) }
        var lx = leftStick.vector.dx, ly = leftStick.vector.dy
        if cutlery.dpadAsStick && !leftStick.active {
            // 십자키 → 왼스틱 축 (스틱 없는 배치용). 이때 십자키 버튼 비트는 빼서 게임의 십자키 기능(줌 등)이 같이 눌리지 않게
            lx = pressed.contains(.right) ? 1 : pressed.contains(.left) ? -1 : 0
            ly = pressed.contains(.down) ? 1 : pressed.contains(.up) ? -1 : 0
            for b in [PadButton.up, .down, .left, .right] { mask &= ~(1 << UInt32(b.rawValue)) }
        }
        let lt = pressed.contains(.lt) ? 1.0 : 0.0, rt = pressed.contains(.rt) ? 1.0 : 0.0
        let msg = String(format: "window.__bingsu&&__bingsu.pad(%u,%.3f,%.3f,%.3f,%.3f,%.1f,%.1f)", mask,
                         lx, ly, rightStick.vector.dx, rightStick.vector.dy, lt, rt)
        guard msg != lastSent else { return }
        lastSent = msg
        webView?.evaluateJavaScript(msg) { _, err in if let err { NSLog("[Spoon] pad send error: \(err.localizedDescription)") } }
    }

    private func sendKeyboard() {
        var want: Set<String> = []
        for b in pressed { if let k = cutlery.keys[b] { want.insert(k) } }
        // 스틱 → 방향키 (4방향 기본, 8방향 옵션)
        let v = leftStick.vector
        if hypot(v.dx, v.dy) > 0.35 {
            let dirs = Self.directions(v, eightWay: eightWay)
            for d in dirs { if let k = cutlery.stickKeys[d] { want.insert(k) } }
        }
        for k in keyboardHeld.subtracting(want) { key(k, down: false) }
        for k in want.subtracting(keyboardHeld) { key(k, down: true) }
        keyboardHeld = want
    }

    /// 게임(Phaser 등)은 프레임 단위로 입력을 보므로 누름→뗌이 한 프레임 안에 들어오면 무시된다.
    /// 뗌은 누른 지 최소 `minPress` 뒤에 보낸다.
    private let minPress: TimeInterval = 0.09
    private var downAt: [String: Date] = [:]
    private var pendingUp: [String: DispatchWorkItem] = [:]

    private func key(_ code: String, down: Bool) {
        if down {
            pendingUp[code]?.cancel(); pendingUp[code] = nil
            downAt[code] = Date()
            send(code, down: true)
        } else {
            let elapsed = Date().timeIntervalSince(downAt[code] ?? .distantPast)
            if elapsed >= minPress { send(code, down: false); return }
            let work = DispatchWorkItem { [weak self] in self?.pendingUp[code] = nil; self?.send(code, down: false) }
            pendingUp[code] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (minPress - elapsed), execute: work)
        }
    }

    private func send(_ code: String, down: Bool) {
        if let keySink { keySink(code, down); return }
        webView?.evaluateJavaScript("window.__bingsu&&__bingsu.key('\(code)',\(down))", completionHandler: nil)
    }

    static func directions(_ v: CGVector, eightWay: Bool) -> [PadButton] {
        let angle = atan2(-v.dy, v.dx) // 위가 +
        let deg = angle * 180 / .pi
        if eightWay {
            var out: [PadButton] = []
            if deg > 22.5 && deg < 157.5 { out.append(.up) }
            if deg < -22.5 && deg > -157.5 { out.append(.down) }
            if abs(deg) < 67.5 { out.append(.right) }
            if abs(deg) > 112.5 { out.append(.left) }
            return out
        }
        if abs(v.dx) > abs(v.dy) { return [v.dx > 0 ? .right : .left] }
        return [v.dy < 0 ? .up : .down]
    }
}
