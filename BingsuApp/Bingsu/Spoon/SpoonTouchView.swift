import SwiftUI
import UIKit

/// 멀티터치를 받는 투명 뷰. 패드 영역(스틱 존, 버튼 터치 영역) 안의 터치만 가로채고
/// 나머지는 아래 게임(웹뷰)으로 그대로 보낸다 (7.3 터치 규칙).
/// 손가락이 처음 닿은 곳 기준으로 뗄 때까지 같은 대상을 유지하되, 버튼끼리는 미끄러뜨려 옮길 수 있다.
final class SpoonTouchUIView: UIView {
    var controller: SpoonController?
    var layout = SpoonLayout()

    private enum Target { case leftStick, rightStick, button(PadButton), dpad(PadButton), dpadFloat(PadButton?) }
    private var targets: [ObjectIdentifier: Target] = [:]
    /// 떠다니는 십자키의 지금 중심 (한 손가락만)
    private var floatCenter: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError() }


    /// 패드 영역 밖은 nil → 터치가 게임으로 통과
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        return inPadRegion(point) ? self : nil
    }

    private func inPadRegion(_ p: CGPoint) -> Bool {
        let l = layout
        if let s = l.leftStick, s.zone.contains(p) { return true }
        if let s = l.rightStick, s.zone.contains(p) { return true }
        if l.button(at: p) != nil { return true }
        if let z = l.dpadZone, z.contains(p) { return true }
        if let c = l.dpadCenter, hypot(p.x - c.x, p.y - c.y) <= l.dpadRadius * 1.3 { return true }
        return false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let c = controller else { return }
        let l = layout
        for t in touches {
            let p = t.location(in: self)
            let id = ObjectIdentifier(t)
            if let b = l.button(at: p) {
                targets[id] = .button(b); c.press(b); continue
            }
            // 떠다니는 십자키: 영역 안에 처음 댄 자리가 중심. 방향은 움직여야 정해진다
            if let z = l.dpadZone, floatCenter == nil, z.contains(p) {
                floatCenter = p; c.dpadFloatCenter = p; targets[id] = .dpadFloat(nil); continue
            }
            if let d = l.dpadButton(at: p) {
                targets[id] = .dpad(d); c.press(d); continue
            }
            if let s = l.rightStick, s.zone.contains(p), !c.rightStick.active {
                targets[id] = .rightStick; c.stickBegan(right: true, at: p, slot: s); continue
            }
            if let s = l.leftStick, s.zone.contains(p), !c.leftStick.active {
                targets[id] = .leftStick; c.stickBegan(right: false, at: p, slot: s); continue
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let c = controller else { return }
        let l = layout
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let target = targets[id] else { continue }
            let p = t.location(in: self)
            switch target {
            case .leftStick: if let s = l.leftStick { c.stickMoved(right: false, to: p, slot: s) }
            case .rightStick: if let s = l.rightStick { c.stickMoved(right: true, to: p, slot: s) }
            case .button(let old):
                // 손가락 미끄러뜨리기: 다른 버튼 위로 가면 바꿔 누른다
                let new = l.button(at: p)
                if new != old { c.release(old); if let n = new { c.press(n) }; targets[id] = new.map { .button($0) } ?? .button(old) }
                if new == nil { targets[id] = .button(old) }
            case .dpad(let old):
                let new = l.dpadButton(at: p)
                if new != old { c.release(old); if let n = new { c.press(n); targets[id] = .dpad(n) } }
            case .dpadFloat(let old):
                guard let fc = floatCenter else { continue }
                let dx = p.x - fc.x, dy = p.y - fc.y
                // 중심에서 조금(반지름의 1/5) 벗어나면 방향. 바깥 한계는 없다 (손가락이 멀리 가도 그 방향 유지)
                let new: PadButton? = hypot(dx, dy) > l.dpadRadius * 0.2
                    ? (abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)) : nil
                if new != old {
                    if let old { c.release(old) }
                    if let new { c.press(new) }
                    targets[id] = .dpadFloat(new)
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        guard let c = controller else { return }
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let target = targets.removeValue(forKey: id) else { continue }
            switch target {
            case .leftStick: c.stickEnded(right: false)
            case .rightStick: c.stickEnded(right: true)
            case .button(let b), .dpad(let b): c.release(b)
            case .dpadFloat(let b):
                if let b { c.release(b) }
                floatCenter = nil; c.dpadFloatCenter = nil
            }
        }
    }
}

struct SpoonTouchView: UIViewRepresentable {
    let controller: SpoonController
    let layout: SpoonLayout

    func makeUIView(context: Context) -> SpoonTouchUIView {
        let v = SpoonTouchUIView()
        v.controller = controller
        v.layout = layout
        return v
    }

    func updateUIView(_ v: SpoonTouchUIView, context: Context) {
        v.controller = controller
        v.layout = layout
    }
}
