import SwiftUI
import UIKit

/// 가상 패드의 생김새 한 벌 (화면 "스킨"). 자리는 들어 있지 않고 요소별 색·그림만 가진다 — 자리는 `SpoonLayout`.
/// 기본은 "얼음 조각"(버튼 보드 B3, 2026-10-30 사용자 선택: 흐림 합성이 없어 게임 위에서 발열 비용이 거의 없다).
/// 가상 패드와 일시정지 눈송이 버튼이 같은 값을 써서 한 벌로 보인다. 파일(`skin.json` + PNG)은 `SkinShelf` 가 읽고 검사한다.
struct SpoonSkin {
    static let defaultID = "ice"

    var id = SpoonSkin.defaultID, name = "얼음", author: String? = nil, license: String? = nil, note: String? = nil
    /// 테두리·위쪽 빛의 색
    var ink = Color.white
    /// 버튼 글자·십자키 화살표 색. nil = ink
    var text: Color? = nil
    /// 버튼 바탕 단색. nil = 투명 위에 빛·그늘 그라데이션만
    var fill: Color? = nil
    /// 아래쪽 그늘 색
    var shade = Color.black
    /// 채움 위(빛)·아래(그늘) 진하기 (불투명도 설정 0.25~0.9 에 곱함)
    var fillTop = 0.3, shadeBottom = 0.3
    /// 테두리 진하기
    var rim = 1.1
    var lineWidth: CGFloat = 1
    /// 눌렸을 때 채우는 색 (상태색 "원활" 하늘색)
    var press = Color(red: 0.43, green: 0.76, blue: 0.91)
    /// 십자키·스틱 바탕색. nil = fill
    var dpadFill: Color? = nil, stickFill: Color? = nil

    /// 둥근 버튼 모양. 알약은 늘 캡슐, 십자키는 늘 십자
    enum Shape: Equatable { case circle, squircle(corner: CGFloat) }
    var shape = Shape.circle

    /// 버튼 글자 세트 (README "labels.style")
    enum LabelStyle: String, CaseIterable {
        case xbox, `switch`, playstation, retro, none
        var title: String {
            switch self {
            case .xbox: return "Xbox"; case .switch: return "스위치"; case .playstation: return "PlayStation"
            case .retro: return "레트로"; case .none: return "글자 없음"
            }
        }
    }
    var labelStyle = LabelStyle.xbox
    var font = Font.Design.rounded
    /// 버튼별 글자 덮어쓰기 (8자까지)
    var overrides: [PadButton: String] = [:]
    /// 버튼별 바탕색 (fill 대신)
    var buttonColors: [PadButton: Color] = [:]

    /// 그림 한 장 (처음 쓸 때 512px 이하로 한 번 디코딩한 것). capInsets 는 디코딩한 그림의 픽셀 기준
    struct Picture {
        var normal: UIImage
        var pressed: UIImage? = nil
        var pressedArm: UIImage? = nil
        var capInsets: UIEdgeInsets? = nil
        var showsLabel = true
    }
    /// 키: "button.a"…"button.r3", "button.round", "button.pill", "dpad", "stick.base", "stick.knob", "orb"
    var images: [String: Picture] = [:]
    var isBundled = true

    static let ice = SpoonSkin()

    var textColor: Color { text ?? ink }
    var hasImages: Bool { !images.isEmpty }

    /// 버튼 그림: 그 버튼만의 그림 → 둥근/알약 공통 그림
    func picture(for slot: PadButtonSlot) -> Picture? {
        images["button." + slot.button.name] ?? images[slot.pill ? "button.pill" : "button.round"]
    }

    /// 버튼 바탕색: 버튼별 색 → fill
    func fill(for b: PadButton) -> Color? { buttonColors[b] ?? fill }

    /// 눌렸을 때 채우는 색: 버튼별 색이 있으면 그 색을 25% 밝게, 없으면 press
    func pressFill(for b: PadButton) -> Color {
        guard let c = buttonColors[b] else { return press }
        return c.lightened(0.25)
    }

    /// 버튼 글자: 덮어쓰기 → 배치가 정한 글자(L·R·SELECT…) → 글자 세트 → 기본 글자. 글자 없음 세트면 nil
    func glyph(_ b: PadButton, layoutLabel: String?) -> String? {
        if let o = overrides[b] { return o }
        if labelStyle == .none { return nil }
        return layoutLabel ?? Self.styleGlyphs[labelStyle]?[b] ?? b.glyph
    }

    /// README 의 네 세트. xbox 는 PadButton.glyph 그대로
    static let styleGlyphs: [LabelStyle: [PadButton: String]] = [
        .switch: [.a: "A", .b: "B", .x: "X", .y: "Y", .lb: "L", .rb: "R", .lt: "ZL", .rt: "ZR", .view: "−", .menu: "+"],
        .playstation: [.a: "○", .b: "×", .x: "△", .y: "□", .lb: "L1", .rb: "R1", .lt: "L2", .rt: "R2", .view: "SHARE", .menu: "OPTIONS"],
        .retro: [.a: "A", .b: "B", .x: "X", .y: "Y", .lb: "L", .rb: "R", .lt: "L2", .rt: "R2", .view: "SELECT", .menu: "START"],
    ]

    /// 스킨 글자·색을 쓸 수 있는 버튼 (README "a b x y lb rb lt rt view menu l3 r3")
    static let skinButtons: [PadButton] = [.a, .b, .x, .y, .lb, .rb, .lt, .rt, .view, .menu, .l3, .r3]

    /// 글꼴 이름 (skin.json "labels.font")
    static let fonts: [(String, Font.Design, String)] = [
        ("rounded", .rounded, "둥근"), ("default", .default, "기본"), ("mono", .monospaced, "고정폭"), ("serif", .serif, "명조"),
    ]
}

extension Color {
    /// `#RRGGBB` / `#RRGGBBAA`. 틀리면 nil
    init?(skinHex s: String) {
        guard s.count == 7 || s.count == 9, s.first == "#", let v = UInt64(s.dropFirst(), radix: 16) else { return nil }
        let rgba = s.count == 7 ? (v << 8) | 0xFF : v
        self.init(.sRGB, red: Double((rgba >> 24) & 0xFF) / 255, green: Double((rgba >> 16) & 0xFF) / 255,
                  blue: Double((rgba >> 8) & 0xFF) / 255, opacity: Double(rgba & 0xFF) / 255)
    }

    /// `#RRGGBB`, 불투명하지 않으면 `#RRGGBBAA` (스킨 만들기에서 저장할 때)
    var skinHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func h(_ v: CGFloat) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + h(r) + h(g) + h(b) + (a < 0.999 ? h(a) : "")
    }

    /// 밝기 (눌림 글자를 검게/희게 고를 때)
    var luminance: Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    func lightened(_ f: Double) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func l(_ v: CGFloat) -> Double { Double(v) + (1 - Double(v)) * f }
        return Color(.sRGB, red: l(r), green: l(g), blue: l(b), opacity: Double(a))
    }
}
