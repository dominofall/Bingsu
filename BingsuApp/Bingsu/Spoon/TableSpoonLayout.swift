import Foundation
import CoreGraphics

/// iPhone 컨트롤러 화면의 배치 종류 (설정 `tableSpoon.kind`). 전용 하나 + 게임 패드 종류 셋을 화면 전체 크기로
enum TableSpoonKind: String, CaseIterable {
    case dedicated   // 전용: 큰 십자키(떠다니기 가능) + ABXY(스위치 순서) + L/R + −·+
    case standard    // 스틱: 움직이는 스틱 + ABXY(Xbox 순서) + LB/RB/LT/RT + ⧉/≡
    case full        // Xbox 전체: + 십자키 + 오른쪽 스틱
    case retro       // 레트로: 큰 십자키 + B·A + SELECT·START
    case oneHand     // 한손: 세로로 들었을 때 엄지 하나 (가로로 돌리면 기본과 같음)

    var label: String {
        switch self {
        case .dedicated: return "기본 (십자키)"; case .standard: return "스틱"; case .full: return "Xbox 전체"; case .retro: return "레트로"
        case .oneHand: return "한손 (세로)"
        }
    }
    var hasStick: Bool { self == .standard || self == .full }
    var padKind: PadKind? { PadKind(rawValue: rawValue) }
}

extension SpoonLayout {
    /// iPhone 컨트롤러 화면의 배치. 가로 전용은 `makeController(size:…)`, 나머지는 게임 패드 배치(가로·세로·한손)를 1.25~1.3배로
    /// (게임이 밑에 없어 화면을 더 써도 된다). 세로에서 "기본" 은 세로 기본 배치에 떠다니는 십자키 영역을 얹는다 (2026-11-10 세로 추가).
    /// 어느 종류든 ABXY 사이 빈 곳은 가장 가까운 버튼으로 (`snapRadius`).
    static func makeController(kind: TableSpoonKind, size: CGSize, safe: Insets, scale user: CGFloat, floatingDpad: Bool, leftHanded: Bool = false) -> SpoonLayout {
        let portrait = size.height > size.width
        if kind == .dedicated && !portrait { return makeController(size: size, safe: safe, scale: user, floatingDpad: floatingDpad) }
        let k = min(max(min(size.width, size.height) / 393, 0.9), 1.15) * user
        var l = make(size: size, safe: safe, kind: kind.padKind ?? .simple, scale: k * (portrait ? 1.3 : 1.25), floatingStick: true, leftHanded: leftHanded, idiom: .phone)
        if kind == .dedicated, floatingDpad, let c = l.dpadCenter {
            // 세로 기본: 십자키 쪽 절반, 십자키 조금 위부터 바닥까지
            let top = c.y - l.dpadRadius * 1.6
            l.dpadZone = CGRect(x: c.x < size.width / 2 ? 0 : size.width / 2, y: top, width: size.width / 2, height: size.height - top)
        }
        let face = l.buttons.filter { !$0.pill }
        if let a = face.first(where: { $0.button == .a }), let b = face.first(where: { $0.button == .b }) {
            l.snapRadius = hypot(a.center.x - b.center.x, a.center.y - b.center.y) + a.radius + 24 * k
        }
        return l
    }

    /// iPhone 컨트롤러 화면 전용 배치 (docs/iphone-pad/CONDITIONS.md 조건 1·2·4). 가로 화면, 게임이 밑에 없으니 화면 전체를 쓴다.
    /// 좌표는 짧은 변 393pt(6.1") 기준이고 기기 비율 `k`(mini 0.95 … 6.9" 1.12)에 사용자 크기를 곱한다.
    /// - 왼쪽 아래 큰 십자키(반지름 84). `floatingDpad` 면 왼쪽 절반 아무 데나 댄 자리가 중심
    /// - 오른쪽 아래 ABXY 마름모(스위치 순서, 반지름 34·간격 60). 사이 빈 곳은 가장 가까운 버튼으로 (`snapRadius`)
    /// - 위 양 모서리 L·R 큰 알약, 위 가운데 −·+
    static func makeController(size: CGSize, safe: Insets, scale user: CGFloat, floatingDpad: Bool) -> SpoonLayout {
        let W = size.width, H = size.height
        let k = min(max(min(W, H) / 393, 0.9), 1.15) * user
        var l = SpoonLayout()
        let bottom = H - max(safe.bottom, 14)
        let leftX = max(safe.left, 20), rightX = W - max(safe.right, 20)
        let topY = max(safe.top, 10)

        let dr = 84 * k
        l.dpadCenter = CGPoint(x: leftX + 36 * k + dr, y: bottom - 30 * k - dr)
        l.dpadRadius = dr
        if floatingDpad { l.dpadZone = CGRect(x: 0, y: H * 0.22, width: W * 0.46, height: H * 0.78) }

        let r = 34 * k, gap = 60 * k
        let cx = rightX - 36 * k - gap - r, cy = bottom - 30 * k - gap - r
        l.buttons += abxySwitch(cx: cx, cy: cy, gap: gap, r: r)
        l.snapRadius = gap + r + 28 * k

        let pr = 26 * k
        l.buttons += [
            PadButtonSlot(button: .lb, center: CGPoint(x: leftX + 24 * k + pr * 1.5, y: topY + 18 * k + pr), radius: pr, pill: true, label: "L", stretch: 1.5),
            PadButtonSlot(button: .rb, center: CGPoint(x: rightX - 24 * k - pr * 1.5, y: topY + 18 * k + pr), radius: pr, pill: true, label: "R", stretch: 1.5),
        ]
        let sr = 18 * k
        l.buttons += [
            PadButtonSlot(button: .view, center: CGPoint(x: W / 2 - 64 * k, y: topY + 14 * k + sr), radius: sr, pill: true, label: "−"),
            PadButtonSlot(button: .menu, center: CGPoint(x: W / 2 + 64 * k, y: topY + 14 * k + sr), radius: sr, pill: true, label: "+"),
        ]
        return l
    }
}
