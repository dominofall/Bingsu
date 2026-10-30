import Foundation
import GameController
import Combine

/// 홈(게임 목록)에서 실제 컨트롤러로 게임칩을 고르는 탐색기.
/// 십자키·왼스틱으로 초점 이동, A 로 열기, 메뉴(≡/+) 로 설정.
/// 게임 쪽 `LongSpoon` 은 프로필 전체 핸들러(`valueChangedHandler`)를 쓰고
/// 여기서는 요소별 핸들러만 걸어 둘이 겹쳐도 서로 지우지 않는다.
@MainActor
final class MenuPadNavigator: ObservableObject {
    enum Move { case up, down, left, right }

    /// 초점이 간 칩 인덱스. 게임 수 == 마지막 인덱스는 "게임 추가" 칩.
    @Published var focus: Int?
    @Published private(set) var connected = false

    /// 홈이 보이고 시트가 없을 때만 입력을 받는다
    var active = false { didSet { if !active { stopRepeat() } } }
    var count = 0
    var columns = 2
    var onSelect: ((Int) -> Void)?
    var onSettings: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var pads: [ObjectIdentifier: GCController] = [:]
    private var heldMove: Move?
    private var repeatTimer: Timer?
    private var stickMove: Move?

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in if let c = n.object as? GCController { self?.attach(c) } }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in if let c = n.object as? GCController { self?.detach(c) } }
        })
        for c in GCController.controllers() { attach(c) }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        repeatTimer?.invalidate()
    }

    private func attach(_ c: GCController) {
        guard let p = c.extendedGamepad, !c.isSnapshot else { return }
        pads[ObjectIdentifier(c)] = c
        connected = true
        p.dpad.valueChangedHandler = { [weak self] _, x, y in
            Task { @MainActor in self?.hold(Self.move(x: x, y: y, on: 0.5, off: 0.5)) }
        }
        p.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            Task { @MainActor in
                guard let self else { return }
                // 스틱은 디지털처럼: 0.6 넘으면 켜고 0.3 아래로 내려와야 꺼진다
                let m = Self.move(x: x, y: y, on: 0.6, off: 0.3, current: self.stickMove)
                self.stickMove = m
                self.hold(m)
            }
        }
        p.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in if pressed { self?.select() } }
        }
        p.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in if pressed, let self, self.active { self.onSettings?() } }
        }
    }

    private func detach(_ c: GCController) {
        pads[ObjectIdentifier(c)] = nil
        if let p = c.extendedGamepad {
            p.dpad.valueChangedHandler = nil
            p.leftThumbstick.valueChangedHandler = nil
            p.buttonA.pressedChangedHandler = nil
            p.buttonMenu.pressedChangedHandler = nil
        }
        connected = !pads.isEmpty
        stopRepeat()
        if !connected { focus = nil }
    }

    /// 축 값 → 방향. `current` 가 있으면 `off` 보다 작아질 때까지 유지(히스테리시스).
    private static func move(x: Float, y: Float, on: Float, off: Float, current: Move? = nil) -> Move? {
        let mag = max(abs(x), abs(y))
        if let current, mag >= off { return current }
        guard mag >= on else { return nil }
        if abs(x) >= abs(y) { return x > 0 ? .right : .left }
        return y > 0 ? .up : .down   // GameController 는 위가 +
    }

    /// 방향을 누르고 있으면 처음 한 번 움직이고, 잠시 뒤부터 반복한다
    private func hold(_ m: Move?) {
        guard m != heldMove else { return }
        heldMove = m
        stopRepeat()
        guard let m, active else { return }
        step(m)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.heldMove == m else { return }
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: true) { [weak self] _ in
                    Task { @MainActor in if let self, self.heldMove == m { self.step(m) } }
                }
            }
        }
    }

    private func stopRepeat() { repeatTimer?.invalidate(); repeatTimer = nil }

    private func step(_ m: Move) {
        guard active, count > 0 else { return }
        guard let f = focus else { focus = 0; return }
        let cols = max(1, columns)
        var next = f
        switch m {
        case .left: next = f - 1
        case .right: next = f + 1
        case .up: next = f - cols
        case .down: next = f + cols
        }
        // 아래로 갈 자리가 없으면 마지막 칩으로
        if m == .down && next >= count && f < count - 1 { next = count - 1 }
        if next >= 0 && next < count && next != f { focus = next; Rumble.shared.tap(intensity: 0.15) }
    }

    private func select() {
        guard active, let f = focus, f < count else { return }
        onSelect?(f)
    }
}
