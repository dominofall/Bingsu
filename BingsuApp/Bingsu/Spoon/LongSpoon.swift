import Foundation
import GameController
import CoreGraphics

/// 긴 숟가락: 실제 컨트롤러(MFi/Xbox/PS). 입력을 앱이 직접 읽어 SpoonController 로 넣는다.
/// WKWebView 의 Gamepad API 는 사용자 터치 전엔 패드를 안 보여주는 등 제약이 있어 쓰지 않는다.
/// 덕분에 가상 패드가 되는 게임(가상 Xbox 패드·키보드 합성)은 실제 패드도 똑같이 된다.
@MainActor
final class LongSpoon {
    private weak var spoon: SpoonController?
    private var attached: [ObjectIdentifier: GCController] = [:]
    private var observers: [NSObjectProtocol] = []
    /// 게임이 화면에 없을 때(홈으로 나가 멈춘 상태)는 입력을 게임에 보내지 않는다
    var enabled = true { didSet { if !enabled { held.removeAll(); spoon?.releaseAll() } } }
    /// 일시정지 화면이 열려 있으면 버튼을 게임에 보내지 않고 여기로 넘긴다 (새로 눌린 버튼 하나씩, 스틱은 방향 버튼으로).
    /// 이미 누르고 있던 버튼은 다시 넘기지 않도록 `held` 는 그대로 둔다.
    var menuInput: ((PadButton) -> Void)? { didSet { spoon?.releaseAll(); stickDir = nil } }
    /// 게임 중 홈 버튼(가운데 로고 버튼): 일시정지 화면 열기 (7.4)
    var onHomeButton: (() -> Void)?

    init(spoon: SpoonController) {
        self.spoon = spoon
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in if let c = n.object as? GCController { self?.attach(c) } }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in if let c = n.object as? GCController { self?.detach(c) } }
        })
        for c in GCController.controllers() { attach(c) }
    }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    /// 실제 게임패드(확장 프로필)가 하나라도 붙어 있는가. 키보드·마우스·스냅샷은 제외.
    static func anyRealGamepad() -> Bool {
        GCController.controllers().contains { $0.extendedGamepad != nil && !$0.isSnapshot }
    }

    /// 설정 화면에 보여 줄 연결된 게임패드 제품명. 기기 식별자는 넣지 않는다 (8.2).
    /// 제품명 · iOS 가 본 종류(DualShock 4 / Xbox One / Switch Pro Controller 등) · 진동 모터 수. 식별자는 없음.
    static func connectedNames() -> [String] {
        GCController.controllers()
            .filter { $0.extendedGamepad != nil && !$0.isSnapshot }
            .map { c in
                let name = c.vendorName ?? c.productCategory
                let motors = c.haptics.map { "진동 모터 \($0.supportedLocalities.count)개" } ?? "진동 없음"
                return "\(name) · \(c.productCategory) · \(motors)"
            }
    }

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad, !c.isSnapshot else { return }
        attached[ObjectIdentifier(c)] = c
        pad.valueChangedHandler = { [weak self] pad, _ in
            Task { @MainActor in self?.apply(pad) }
        }
    }

    private func detach(_ c: GCController) {
        attached[ObjectIdentifier(c)] = nil
        c.extendedGamepad?.valueChangedHandler = nil
        spoon?.releaseAll()
    }

    private var held: Set<PadButton> = []
    private var homeHeld = false
    private var stickDir: PadButton?

    private func apply(_ p: GCExtendedGamepad) {
        guard enabled, let s = spoon else { return }
        var now: Set<PadButton> = []
        if p.buttonA.isPressed { now.insert(.a) }
        if p.buttonB.isPressed { now.insert(.b) }
        if p.buttonX.isPressed { now.insert(.x) }
        if p.buttonY.isPressed { now.insert(.y) }
        if p.leftShoulder.isPressed { now.insert(.lb) }
        if p.rightShoulder.isPressed { now.insert(.rb) }
        if p.leftTrigger.isPressed { now.insert(.lt) }
        if p.rightTrigger.isPressed { now.insert(.rt) }
        if p.buttonMenu.isPressed { now.insert(.menu) }
        if p.buttonOptions?.isPressed == true { now.insert(.view) }
        if p.leftThumbstickButton?.isPressed == true { now.insert(.l3) }
        if p.rightThumbstickButton?.isPressed == true { now.insert(.r3) }
        if p.dpad.up.isPressed { now.insert(.up) }
        if p.dpad.down.isPressed { now.insert(.down) }
        if p.dpad.left.isPressed { now.insert(.left) }
        if p.dpad.right.isPressed { now.insert(.right) }
        let homeDown = p.buttonHome?.isPressed == true
        defer { homeHeld = homeDown }
        if let menuInput {
            for b in now.subtracting(held) { menuInput(b) }
            if homeDown && !homeHeld { menuInput(.home) }
            // 스틱은 디지털처럼: 0.6 넘으면 그 방향 한 번, 0.3 아래로 돌아와야 다음
            let x = p.leftThumbstick.xAxis.value, y = p.leftThumbstick.yAxis.value
            let mag = max(abs(x), abs(y))
            if mag < 0.3 { stickDir = nil } else if mag > 0.6, stickDir == nil {
                let d: PadButton = abs(x) > abs(y) ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down)
                stickDir = d; menuInput(d)
            }
            held = now
            return
        }
        if homeDown && !homeHeld { onHomeButton?() }
        for b in held.subtracting(now) { s.release(b, immediate: true) }
        for b in now.subtracting(held) { s.press(b, haptic: false) }
        held = now
        // 스틱: GameController 는 위가 +, Gamepad API 는 아래가 + 라 y 를 뒤집는다
        s.setStick(right: false, vector: CGVector(dx: CGFloat(p.leftThumbstick.xAxis.value), dy: CGFloat(-p.leftThumbstick.yAxis.value)))
        s.setStick(right: true, vector: CGVector(dx: CGFloat(p.rightThumbstick.xAxis.value), dy: CGFloat(-p.rightThumbstick.yAxis.value)))
    }
}
