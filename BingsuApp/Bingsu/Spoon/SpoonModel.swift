import Foundation
import UIKit
import CoreGraphics

/// 표준 게임패드 버튼 (W3C standard mapping 인덱스와 같다)
enum PadButton: Int, CaseIterable, Hashable {
    case a = 0, b, x, y, lb, rb, lt, rt, view, menu, l3, r3, up, down, left, right, home

    var glyph: String {
        switch self {
        case .a: return "A"; case .b: return "B"; case .x: return "X"; case .y: return "Y"
        case .lb: return "LB"; case .rb: return "RB"; case .lt: return "LT"; case .rt: return "RT"
        case .view: return "⧉"; case .menu: return "≡"; case .l3: return "L3"; case .r3: return "R3"
        case .up: return "▲"; case .down: return "▼"; case .left: return "◀"; case .right: return "▶"; case .home: return "⌂"
        }
    }
    var isDpad: Bool { self == .up || self == .down || self == .left || self == .right }
}

/// 패드 종류 (7.4, 9.1 다섯 가지). 처음 기본값은 기본(2026-10-30 사용자 결정). 고르기 목록은 이 순서대로 보인다.
/// 원시값은 저장된 설정(`spoon.kind`, 게임별 Prefs)에 그대로 남으므로 이름이 바뀌어도 바꾸지 않는다 (simple = 예전 "간단하게").
enum PadKind: String, CaseIterable, Codable {
    case simple    // 기본: 십자키 + ABXY(스위치 순서: 위 X·오른쪽 A·아래 B·왼쪽 Y) + L/R + −/+
    case standard  // 스틱: 움직이는 스틱 + ABXY + LB/RB/LT/RT + 보기/메뉴
    case full      // Xbox 전체: + 십자키 + 오른쪽 스틱
    case retro     // 레트로: 큰 십자키 + B·A + SELECT(보기)·START(메뉴)
    case oneHand   // 한손: 세로 화면 전용(엄지 모음). 가로로 돌리면 기본 배치

    var label: String {
        switch self {
        case .simple: return "기본"; case .standard: return "스틱"; case .full: return "Xbox 전체"
        case .retro: return "레트로"; case .oneHand: return "한손 (세로)"
        }
    }
    /// LT/RT 가 있는 배치 (없으면 트리거가 꼭 필요한 게임은 스틱 배치로 연다)
    var hasTriggers: Bool { self == .standard || self == .full }
    /// 왼쪽 스틱이 있는 배치 (움직이는 스틱 설정이 의미 있음)
    var hasStick: Bool { self == .standard || self == .full }
}

/// 화면에 놓인 버튼 하나
struct PadButtonSlot: Identifiable {
    let button: PadButton
    let center: CGPoint
    let radius: CGFloat
    let pill: Bool          // 가로로 긴 모양(LB/RB/LT/RT/보기/메뉴)
    var label: String? = nil  // 표기 덮어쓰기 (스위치 배치의 L/R)
    var stretch: CGFloat = 1.3   // 알약의 반폭 / 반지름 (SELECT·START 처럼 글자가 긴 알약은 더 넓게)
    var id: PadButton { button }
    var width: CGFloat { pill ? radius * stretch * 2 : radius * 2 }
    var glyph: String { label ?? button.glyph }
    /// 보이는 것보다 넓은 터치 영역
    var hitRadius: CGFloat { radius * (pill ? 1.35 : 1.5) }
    func contains(_ p: CGPoint) -> Bool {
        // 넓은 알약(SELECT·START)은 가로로 긴 영역, 나머지는 원
        if pill && stretch > 1.3 { return abs(p.x - center.x) <= radius * (stretch + 0.5) && abs(p.y - center.y) <= radius * 1.5 }
        return hypot(p.x - center.x, p.y - center.y) <= hitRadius
    }
}

/// 스틱 자리
struct StickSlot {
    let zone: CGRect          // 손가락이 닿으면 스틱이 생기는 영역 (움직이는 스틱)
    let restCenter: CGPoint   // 손을 뗐을 때 흐리게 보이는 기본 자리
    let baseRadius: CGFloat
    let knobRadius: CGFloat
    let travel: CGFloat       // 손잡이 최대 이동
    let floating: Bool
    let isRight: Bool
}

/// 패드 배치 계산 (가로 화면 기준)
struct SpoonLayout {
    var buttons: [PadButtonSlot] = []
    var leftStick: StickSlot?
    var rightStick: StickSlot?
    var dpadCenter: CGPoint?
    var dpadRadius: CGFloat = 0
    /// 눈송이 버튼 자리를 배치가 직접 정할 때 (한손). nil 이면 보기/메뉴 사이
    var orbCenter: CGPoint?

    /// 패드 안 눈송이 버튼 자리: 배치가 정한 자리(orbCenter), 없으면 보기/메뉴 사이
    var betweenViewMenu: CGPoint? {
        if let c = orbCenter { return c }
        guard let v = buttons.first(where: { $0.button == .view }), let m = buttons.first(where: { $0.button == .menu }) else { return nil }
        // 가운데에서 살짝 아래 (버튼 반지름만큼) — 두 버튼과 같은 줄에 끼어 답답해 보이지 않게
        return CGPoint(x: (v.center.x + m.center.x) / 2, y: (v.center.y + m.center.y) / 2 + v.radius * 1.2)
    }

    /// 가로 화면: 왼쪽 묶음의 오른쪽 끝, 오른쪽 묶음의 왼쪽 끝 (게임을 그 사이에 놓을 때 씀)
    func sideEdges(width W: CGFloat) -> (left: CGFloat, right: CGFloat)? {
        var leftMax: CGFloat? = nil, rightMin: CGFloat? = nil
        func add(_ x0: CGFloat, _ x1: CGFloat, center cx: CGFloat) {
            if cx < W / 2 { leftMax = max(leftMax ?? -.infinity, x1) } else { rightMin = min(rightMin ?? .infinity, x0) }
        }
        for b in buttons where b.button != .view && b.button != .menu {   // 보기/메뉴(아래 가운데)는 세로 여백으로 피한다
            let half = b.width / 2
            add(b.center.x - half, b.center.x + half, center: b.center.x)
        }
        if let s = leftStick { add(s.restCenter.x - s.baseRadius, s.restCenter.x + s.baseRadius, center: s.restCenter.x) }
        if let s = rightStick { add(s.restCenter.x - s.baseRadius, s.restCenter.x + s.baseRadius, center: s.restCenter.x) }
        if let c = dpadCenter { add(c.x - dpadRadius, c.x + dpadRadius, center: c.x) }
        guard let l = leftMax, let r = rightMin, r > l else { return nil }
        return (l, r)
    }

    /// 패드 요소들의 맨 위 y (세로 화면에서 게임을 그 위 공간에 놓을 때 씀). 요소가 없으면 nil.
    var topEdge: CGFloat? {
        var ys: [CGFloat] = buttons.map { $0.center.y - $0.radius }
        if let s = leftStick { ys.append((s.floating ? s.zone.minY : s.restCenter.y - s.baseRadius)) }
        if let s = rightStick { ys.append(s.restCenter.y - s.baseRadius) }
        if let c = dpadCenter { ys.append(c.y - dpadRadius) }
        return ys.min()
    }

    /// iPad 는 화면이 커서 같은 배율이면 버튼이 작게 느껴진다. 설정 배율에 기기 배수를 곱한다 (2026-10-29 iPad 점검).
    static var deviceFactor: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 1.4 : 1 }

    /// `shoulderArc`: L·R 을 엄지 원호 위에 둔다 (기본은 iPad 에서만, 2026-10-30 사용자 선택 4-A)
    static func make(size: CGSize, safe: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat),
                     kind: PadKind, scale requested: CGFloat, floatingStick: Bool, leftHanded: Bool = false,
                     shoulderArc: Bool = UIDevice.current.userInterfaceIdiom == .pad) -> SpoonLayout {
        let W = size.width, H = size.height
        let requested = requested * deviceFactor
        if H > W {
            if kind == .oneHand { return makeOneHand(size: size, safe: safe, scale: requested, leftHanded: leftHanded) }
            return makePortrait(size: size, safe: safe, kind: kind, scale: requested, floatingStick: floatingStick)
        }
        // 한손은 세로 전용: 가로로 돌리면 기본 배치
        let kind: PadKind = kind == .oneHand ? .simple : kind
        let scale = requested
        var l = SpoonLayout()
        let r = 26 * scale                       // 둥근 버튼 반지름
        let gap = 46 * scale                     // ABXY 간격
        let bottom = H - max(safe.bottom, 12) - 24 * scale
        let rightX = W - max(safe.right, 16) - 24 * scale
        let leftX = max(safe.left, 16) + 24 * scale
        let cx = rightX - gap - r, cy = bottom - gap - r          // 오른쪽 묶음 가운데
        let stickBase = CGPoint(x: leftX + 70 * scale, y: bottom - 70 * scale)   // 왼쪽 묶음 가운데
        let sr = 15 * scale

        switch kind {
        case .simple, .oneHand:
            // 기본: 십자키 + ABXY 마름모(스위치 순서) + −/+(아래 가운데)
            l.dpadCenter = stickBase; l.dpadRadius = 62 * scale
            l.buttons += abxySwitch(cx: cx, cy: cy, gap: gap, r: r)
            l.buttons += [
                PadButtonSlot(button: .view, center: CGPoint(x: W / 2 - 48 * scale, y: bottom - sr), radius: sr, pill: true, label: "−"),
                PadButtonSlot(button: .menu, center: CGPoint(x: W / 2 + 48 * scale, y: bottom - sr), radius: sr, pill: true, label: "+"),
            ]
        case .retro:
            // 레트로: 큰 십자키 + 비스듬한 B·A + SELECT·START
            l.dpadCenter = stickBase; l.dpadRadius = 66 * scale
            l.buttons += retroButtons(cx: cx, cy: cy, scale: scale)
            l.buttons += selectStart(y: bottom - 11 * scale, midX: W / 2, scale: scale)
        case .standard, .full:
            l.buttons += abxy(cx: cx, cy: cy, gap: gap, r: r)
            l.buttons += [
                PadButtonSlot(button: .view, center: CGPoint(x: W / 2 - 48 * scale, y: bottom - sr), radius: sr, pill: true),
                PadButtonSlot(button: .menu, center: CGPoint(x: W / 2 + 48 * scale, y: bottom - sr), radius: sr, pill: true),
            ]
            l.leftStick = StickSlot(zone: CGRect(x: 0, y: H * 0.15, width: W * 0.4, height: H * 0.85),
                                    restCenter: stickBase, baseRadius: 48 * scale, knobRadius: 22 * scale,
                                    travel: 34 * scale, floating: floatingStick, isRight: false)
        }

        // 숄더: 기본은 L·R 하나씩, 스틱·Xbox 전체는 LB/RB/LT/RT, 레트로는 없음
        let shoulders: [(PadButton, String?)] = kind == .simple ? [(.lb, "L"), (.rb, "R")]
            : kind.hasTriggers ? [(.lt, nil), (.lb, nil), (.rt, nil), (.rb, nil)] : []
        if shoulderArc {
            l.buttons += arcShoulders(shoulders, size: size, left: stickBase, right: CGPoint(x: cx, y: cy), scale: scale)
        } else {
            // 위쪽 모서리 알약: 트리거가 맨 위, 숄더가 그 아래
            let pr = 23 * scale, topY = max(safe.top, 10) + 20 * scale
            for (b, label) in shoulders {
                let isLeft = b == .lb || b == .lt
                let y = (b == .lb || b == .rb) && kind.hasTriggers ? topY + 50 * scale : topY
                l.buttons.append(PadButtonSlot(button: b, center: CGPoint(x: isLeft ? leftX + 34 * scale : rightX - 34 * scale, y: y),
                                               radius: pr, pill: true, label: label))
            }
        }

        if kind == .full {
            l.dpadCenter = CGPoint(x: leftX + 200 * scale, y: bottom - 54 * scale); l.dpadRadius = 54 * scale
            let rc = CGPoint(x: rightX - 190 * scale, y: bottom - 52 * scale)
            l.rightStick = StickSlot(zone: CGRect(x: rc.x - 60 * scale, y: rc.y - 60 * scale, width: 120 * scale, height: 120 * scale),
                                     restCenter: rc, baseRadius: 40 * scale, knobRadius: 18 * scale, travel: 26 * scale,
                                     floating: false, isRight: true)
        }
        return l
    }

    /// iPad: 엄지 뿌리(화면 아래 구석)를 중심으로 한 호 위에 L·R (배그 모바일식). ABXY·스틱에서 엄지를 조금 올리면 닿는다.
    /// 좌우는 같은 반지름으로 대칭. 버튼은 둥글게(호 위에서 알약은 기울어 보여서).
    private static func arcShoulders(_ list: [(PadButton, String?)], size: CGSize, left: CGPoint, right: CGPoint,
                                     scale: CGFloat) -> [PadButtonSlot] {
        guard !list.isEmpty else { return [] }
        let pr = CGPoint(x: size.width - 30, y: size.height - 30), pl = CGPoint(x: 30, y: size.height - 30)
        let R = max(hypot(pr.x - right.x, pr.y - right.y), hypot(pl.x - left.x, pl.y - left.y)) + 105 * scale
        let single = list.count == 2
        return list.compactMap { b, label in
            let deg: CGFloat
            switch b {
            case .rb: deg = single ? 227 : 212
            case .rt: deg = 242
            case .lb: deg = single ? -47 : -32
            case .lt: deg = -62
            default: return nil
            }
            let p = (b == .rb || b == .rt) ? pr : pl, a = deg * .pi / 180
            return PadButtonSlot(button: b, center: CGPoint(x: p.x + R * cos(a), y: p.y + R * sin(a)),
                                 radius: 25 * scale, pill: false, label: label)
        }
    }

    /// 레트로 B·A: 게임보이처럼 왼쪽 아래 B, 오른쪽 위 A
    private static func retroButtons(cx: CGFloat, cy: CGFloat, scale: CGFloat) -> [PadButtonSlot] {
        [
            PadButtonSlot(button: .b, center: CGPoint(x: cx - 18 * scale, y: cy + 26 * scale), radius: 32 * scale, pill: false),
            PadButtonSlot(button: .a, center: CGPoint(x: cx + 54 * scale, y: cy - 14 * scale), radius: 32 * scale, pill: false),
        ]
    }

    /// 레트로 SELECT(보기)·START(메뉴): 글자가 길어 넓은 알약
    private static func selectStart(y: CGFloat, midX: CGFloat, scale: CGFloat) -> [PadButtonSlot] {
        let h = 11 * scale
        return [
            PadButtonSlot(button: .view, center: CGPoint(x: midX - 42 * scale, y: y), radius: h, pill: true, label: "SELECT", stretch: 2.7),
            PadButtonSlot(button: .menu, center: CGPoint(x: midX + 42 * scale, y: y), radius: h, pill: true, label: "START", stretch: 2.7),
        ]
    }

    /// 한손(세로 전용, 2026-10-31 사용자 요청): 엄지 뿌리(손잡이 쪽 아래 모서리)를 중심으로 거리별로 놓는다.
    /// - 가까운 원호(~120pt): 가장 자주 누르는 A·B
    /// - 가운데 원호(~250pt, 엄지가 편히 펴지는 거리): 큰 십자키
    /// - 위쪽(~200–270pt): X·Y, 그 위 L·R / 아래 줄: −·+
    /// - 눈송이는 엄지를 일부러 굽혀야 닿는 모서리 (잘못 눌러 멈추지 않게)
    /// 버튼은 지름 64pt·알약 높이 44pt 아래로 줄이지 않는다. `leftHanded` 면 좌우를 뒤집는다.
    static func makeOneHand(size: CGSize, safe: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat),
                            scale requested: CGFloat, leftHanded: Bool) -> SpoonLayout {
        let W = size.width, H = size.height
        let edge = max(safe.left, 16), right = W - max(safe.right, 16)
        // 작은 배율은 한손에서 누르기 어려우므로 0.95 아래로는 내리지 않고, 폭이 모자랄 때만 줄인다
        let s = min(max(requested, 0.95), (right - edge) / 300)
        let bottom = H - max(safe.bottom, 12)
        // (손잡이 쪽 가장자리에서 안쪽으로 dx, 아래에서 위로 dy)
        func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            CGPoint(x: leftHanded ? edge + dx * s : right - dx * s, y: bottom - dy * s)
        }
        let r = max(32 * s, 30), pr = max(22 * s, 20)
        var l = SpoonLayout()
        l.dpadCenter = at(192, 161); l.dpadRadius = max(80 * s, 70)
        l.buttons = [
            PadButtonSlot(button: .a, center: at(69, 98), radius: r, pill: false),
            PadButtonSlot(button: .b, center: at(119, 39), radius: r, pill: false),
            PadButtonSlot(button: .x, center: at(36, 197), radius: r, pill: false),
            PadButtonSlot(button: .y, center: at(100, 245), radius: r, pill: false),
            PadButtonSlot(button: .lb, center: at(leftHanded ? 40 : 205, 302), radius: pr, pill: true, label: "L"),
            PadButtonSlot(button: .rb, center: at(leftHanded ? 205 : 40, 302), radius: pr, pill: true, label: "R"),
            PadButtonSlot(button: .view, center: at(leftHanded ? 205 : 268, 30), radius: pr, pill: true, label: "−"),
            PadButtonSlot(button: .menu, center: at(leftHanded ? 268 : 205, 30), radius: pr, pill: true, label: "+"),
        ]
        l.orbCenter = at(14, 14)
        return l
    }

    /// 세로 화면: 폭이 좁으므로 두 묶음(왼쪽 스틱/십자키, 오른쪽 ABXY)을 아래에 나란히 두고,
    /// 보기/메뉴·숄더 버튼은 그 위 줄에 놓는다. 폭에 안 들어가면 크기를 자동으로 줄인다.
    static func makePortrait(size: CGSize, safe: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat),
                             kind: PadKind, scale requested: CGFloat, floatingStick: Bool) -> SpoonLayout {
        let W = size.width, H = size.height
        let margin = max(safe.left, safe.right, 16) + 12
        // 폭 맞춤: 스틱(96) + 사이 공간(36) + ABXY(2*46+2*26=144) 이 (W - 2*margin) 안에 들어가는 최대 배율
        let needed: CGFloat = kind.hasStick ? (96 + 36 + 144) : (124 + 30 + 144)
        let fit = (W - 2 * margin) / needed
        let scale = min(requested, max(0.7, fit))

        var l = SpoonLayout()
        let r = 26 * scale, gap = 46 * scale, pr = 23 * scale, sr = 15 * scale
        let bottom = H - max(safe.bottom, 12) - 20 * scale
        let leftX = margin, rightX = W - margin

        // 아래 줄: 왼쪽 스틱/십자키, 오른쪽 ABXY (A·B)
        let clusterY = bottom - gap - r
        let stickBase = CGPoint(x: leftX + 48 * scale + 8 * scale, y: clusterY)
        if !kind.hasStick {
            // 기본·레트로(한손은 makeOneHand): 아래 줄 십자키 + 오른쪽 버튼, 윗줄 L·R 과 −/+ (레트로는 SELECT·START 만)
            l.dpadCenter = CGPoint(x: leftX + 62 * scale, y: clusterY); l.dpadRadius = 60 * scale
            let cx = rightX - gap - r
            let rowY = clusterY - gap - r - 30 * scale
            if kind == .retro {
                l.buttons += retroButtons(cx: cx, cy: clusterY, scale: scale)
                l.buttons += selectStart(y: rowY, midX: W / 2, scale: scale)
                return l
            }
            l.buttons += abxySwitch(cx: cx, cy: clusterY, gap: gap, r: r)
            l.buttons += [
                PadButtonSlot(button: .lb, center: CGPoint(x: leftX + pr * 1.3, y: rowY), radius: pr, pill: true, label: "L"),
                PadButtonSlot(button: .rb, center: CGPoint(x: rightX - pr * 1.3, y: rowY), radius: pr, pill: true, label: "R"),
                PadButtonSlot(button: .view, center: CGPoint(x: W / 2 - 46 * scale, y: rowY), radius: sr, pill: true, label: "−"),
                PadButtonSlot(button: .menu, center: CGPoint(x: W / 2 + 46 * scale, y: rowY), radius: sr, pill: true, label: "+"),
            ]
            return l
        }
        l.leftStick = StickSlot(zone: CGRect(x: 0, y: clusterY - 120 * scale, width: W * 0.45, height: H - (clusterY - 120 * scale)),
                                restCenter: stickBase, baseRadius: 48 * scale, knobRadius: 22 * scale,
                                travel: 34 * scale, floating: floatingStick, isRight: false)
        let cx = rightX - gap - r
        l.buttons += abxy(cx: cx, cy: clusterY, gap: gap, r: r)

        // 윗줄: 숄더(각 묶음 위), 보기/메뉴(가운데)
        var rowY = clusterY - gap - r - 30 * scale
        if kind == .full {
            // Xbox 전체: 십자키·오른쪽 스틱을 한 줄 더 위에
            l.dpadCenter = CGPoint(x: stickBase.x, y: rowY - 54 * scale); l.dpadRadius = 50 * scale
            let rc = CGPoint(x: cx, y: rowY - 50 * scale)
            l.rightStick = StickSlot(zone: CGRect(x: rc.x - 56 * scale, y: rc.y - 56 * scale, width: 112 * scale, height: 112 * scale),
                                     restCenter: rc, baseRadius: 40 * scale, knobRadius: 18 * scale, travel: 26 * scale,
                                     floating: false, isRight: true)
            rowY -= 120 * scale
        }
        l.buttons += [
            PadButtonSlot(button: .lb, center: CGPoint(x: leftX + pr * 1.3, y: rowY), radius: pr, pill: true),
            PadButtonSlot(button: .lt, center: CGPoint(x: leftX + pr * 1.3, y: rowY - 50 * scale), radius: pr, pill: true),
            PadButtonSlot(button: .rb, center: CGPoint(x: rightX - pr * 1.3, y: rowY), radius: pr, pill: true),
            PadButtonSlot(button: .rt, center: CGPoint(x: rightX - pr * 1.3, y: rowY - 50 * scale), radius: pr, pill: true),
            PadButtonSlot(button: .view, center: CGPoint(x: W / 2 - 46 * scale, y: rowY), radius: sr, pill: true),
            PadButtonSlot(button: .menu, center: CGPoint(x: W / 2 + 46 * scale, y: rowY), radius: sr, pill: true),
        ]
        return l
    }

    /// 스위치 순서: 위 X, 오른쪽 A, 아래 B, 왼쪽 Y (버튼 역할은 그대로, 자리만 다름)
    private static func abxySwitch(cx: CGFloat, cy: CGFloat, gap: CGFloat, r: CGFloat) -> [PadButtonSlot] {
        [
            PadButtonSlot(button: .x, center: CGPoint(x: cx, y: cy - gap), radius: r, pill: false),
            PadButtonSlot(button: .a, center: CGPoint(x: cx + gap, y: cy), radius: r, pill: false),
            PadButtonSlot(button: .b, center: CGPoint(x: cx, y: cy + gap), radius: r, pill: false),
            PadButtonSlot(button: .y, center: CGPoint(x: cx - gap, y: cy), radius: r, pill: false),
        ]
    }

    private static func abxy(cx: CGFloat, cy: CGFloat, gap: CGFloat, r: CGFloat) -> [PadButtonSlot] {
        [
            PadButtonSlot(button: .a, center: CGPoint(x: cx, y: cy + gap), radius: r, pill: false),
            PadButtonSlot(button: .b, center: CGPoint(x: cx + gap, y: cy), radius: r, pill: false),
            PadButtonSlot(button: .x, center: CGPoint(x: cx - gap, y: cy), radius: r, pill: false),
            PadButtonSlot(button: .y, center: CGPoint(x: cx, y: cy - gap), radius: r, pill: false),
        ]
    }

    /// 십자키 방향 판정 (중심 기준 각도, 4방향)
    func dpadButton(at p: CGPoint) -> PadButton? {
        guard let c = dpadCenter else { return nil }
        let dx = p.x - c.x, dy = p.y - c.y
        guard hypot(dx, dy) <= dpadRadius * 1.3, hypot(dx, dy) > dpadRadius * 0.15 else { return nil }
        return abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
    }

    func button(at p: CGPoint) -> PadButton? {
        var best: (PadButton, CGFloat)?
        for s in buttons where s.contains(p) {
            let d = hypot(p.x - s.center.x, p.y - s.center.y)
            if best == nil || d < best!.1 { best = (s.button, d) }
        }
        return best?.0
    }
}

/// 컨트롤러 매핑: 게임마다 버튼의 뜻(꼬리표)과, 패드를 못 읽는 게임을 위한 키보드 대체 키.
struct CutlerySet {
    enum Mode: String { case field, battle }
    enum Transport { case gamepad, keyboard }

    let transport: Transport
    let labels: [Mode: [PadButton: String]]
    /// transport == .keyboard 일 때 버튼 → KeyboardEvent.code
    let keys: [PadButton: String]
    let stickKeys: [PadButton: String]   // up/down/left/right → 키 코드
    /// 게임패드 전송일 때 십자키를 왼스틱 축으로도 보낸다 (기본·레트로처럼 스틱이 없는 배치에서 이동용)
    var dpadAsStick = false
    /// LT/RT 를 꼭 써야 하는 게임. 기본·레트로·한손 배치에는 트리거가 없어서, 게임별로 따로 고르지 않았으면 스틱 배치로 연다
    var needsTriggers = false

    func label(_ b: PadButton, mode: Mode) -> String? { labels[mode]?[b] ?? labels[.field]?[b] }

    /// 포켓몬 레조넌스 — 원작 README 의 Xbox 배치 그대로 (게임이 스스로 매핑하므로 transport 는 gamepad)
    static let resonance = CutlerySet(
        transport: .gamepad,
        labels: [
            .field: [.a: "확인", .b: "취소·달리기", .x: "메뉴", .y: "자전거", .lb: "도감◀", .rb: "도감▶", .view: "달리기 고정", .menu: "메뉴"],
            .battle: [.rt: "기술1", .rb: "기술2", .lt: "기술3", .lb: "기술4", .a: "회피", .b: "몬스터볼", .x: "가방", .y: "볼 종류",
                      .view: "도망", .menu: "일시정지", .r3: "메가진화"],
        ],
        keys: [:], stickKeys: [:], needsTriggers: true)

    /// 패드를 못 읽는 게임의 기본: 흔한 키보드 배치
    static let keyboardDefault = CutlerySet(
        transport: .keyboard,
        labels: [.field: [.a: "확인", .b: "취소", .x: "메뉴", .menu: "메뉴", .view: "달리기"]],
        keys: [.a: "KeyZ", .b: "KeyX", .x: "KeyC", .y: "KeyV", .lb: "KeyA", .rb: "KeyS", .lt: "KeyQ", .rt: "KeyW",
               .view: "ShiftLeft", .menu: "Escape", .up: "ArrowUp", .down: "ArrowDown", .left: "ArrowLeft", .right: "ArrowRight"],
        stickKeys: [.up: "ArrowUp", .down: "ArrowDown", .left: "ArrowLeft", .right: "ArrowRight"])

    /// 웹 게임(포켓로그 등): 자체 터치 UI 가 기본이고, 가상 패드를 켜면 흔한 키보드 배치로 보낸다
    /// (포켓로그: Z 확인, X 취소, C 스탯, Shift 메뉴/전환, Esc 메뉴, 방향키 이동)
    static let webKeyboard = CutlerySet(
        transport: .keyboard,
        labels: [.field: [.a: "Z", .b: "X", .x: "C", .y: "V", .view: "Shift", .menu: "Esc", .lb: "A", .rb: "S", .lt: "Q", .rt: "W"]],
        keys: keyboardDefault.keys, stickKeys: keyboardDefault.stickKeys)

    /// 포켓로그: 가상 Xbox 360 게임패드로 읽힌다. 꼬리표는 포켓로그의 Xbox 기본 매핑
    /// (A 확인, B 취소, X 성격, Y 테라, LB 폼, RB 색, LT 성별, RT 특성, 보기 스탯, 메뉴 메뉴).
    /// keys 는 패드를 못 읽을 때의 키보드 폴백.
    static let pokerogue = CutlerySet(
        transport: .gamepad,
        labels: [.field: [.a: "확인", .b: "취소", .x: "성격", .y: "테라", .menu: "메뉴", .view: "스탯",
                          .lb: "폼", .rb: "색", .lt: "성별", .rt: "특성"]],
        keys: [.a: "KeyZ", .b: "KeyX", .x: "KeyC", .y: "KeyV", .menu: "Escape", .view: "Enter",
               .lb: "KeyF", .rb: "KeyR", .lt: "KeyG", .rt: "KeyE",
               .up: "ArrowUp", .down: "ArrowDown", .left: "ArrowLeft", .right: "ArrowRight"],
        stickKeys: [.up: "ArrowUp", .down: "ArrowDown", .left: "ArrowLeft", .right: "ArrowRight"])

    /// 포켓본크 — 표준 게임패드를 그대로 읽는다 (왼스틱 이동, 오른스틱 카메라, 십자키 줌). 스틱 없는 배치에서는 십자키로 이동.
    static let pokebonk = CutlerySet(
        transport: .gamepad,
        labels: [.field: [.a: "확인", .b: "뒤로"]],
        keys: [:], stickKeys: [:], dpadAsStick: true)

    /// 기본 게임 "Bingsu": A(Z)로 얼음 갈기, 십자키(방향키)로 토핑
    static let sampleGame = CutlerySet(
        transport: .keyboard,
        labels: [.field: [.a: "갈기", .up: "팥", .right: "딸기", .down: "연유", .left: "인절미"]],
        keys: keyboardDefault.keys, stickKeys: keyboardDefault.stickKeys)

    static func forDish(_ dish: Dish) -> CutlerySet {
        if dish.knownWeb == .pokerogue { return .pokerogue }
        if dish.knownWeb == .pokebonk { return .pokebonk }
        if dish.dataPathApp == "pokemon-resonance" || dish.id == "pokemon-resonance" { return .resonance }
        // 진동 실험실(tools/rumble-lab): 표준 게임패드로 읽어야 게임이 vibrationActuator 로 진동을 요청할 수 있다
        if dish.dataPathApp == "bingsu-rumble-lab" { return .pokebonk }
        if dish.id == MenuBoardStore.sampleID { return .sampleGame }
        if dish.recipe == .mkxp { return .rpgMakerXP }   // BrassBowl/CutlerySet+XP.swift
        if dish.isRemote { return CutlerySet(transport: .keyboard, labels: [:], keys: [:], stickKeys: [:]) }
        return .keyboardDefault
    }
}
