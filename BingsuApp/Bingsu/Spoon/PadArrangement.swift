import Foundation
import UIKit

/// 사용자가 편집한 가상 패드 배치 한 벌 (화면 "가상 패드 배치"). 기기·방향·패드 종류마다 하나씩 `PadPrefs.layouts` 에 저장한다.
/// 자리는 안전 영역 안쪽 기준점(anchor)에서의 거리, 단위는 **배치 포인트**(화면 pt ÷ k, k = 크기 슬라이더 × iPad 배율).
/// 그래서 크기 슬라이더와 iPad 배율이 사용자 배치에도 그대로 먹는다. 형식은 `docs/skins/README.md` "배치 파일".
/// iCloud 로 넘어오거나 스킨 zip 에 든 외부 데이터라 믿지 않는다: 읽을 때 값 범위를 자르고 틀린 요소는 그 요소만 버린다.
struct PadArrangement: Codable, Equatable, Sendable {
    enum Anchor: String, Codable, CaseIterable {
        case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isRight: Bool { self == .topRight || self == .bottomRight }
        var isTop: Bool { self == .topLeft || self == .topCenter || self == .topRight }
        /// 좌우 거울
        var mirrored: Anchor {
            switch self {
            case .topLeft: return .topRight; case .topRight: return .topLeft
            case .bottomLeft: return .bottomRight; case .bottomRight: return .bottomLeft
            default: return self
            }
        }
        /// 기준점 (화면 좌표). 안전 영역 안쪽의 모서리·변 가운데. 여백은 x·y 에 들어 있다
        func point(size: CGSize, safe: SpoonLayout.Insets) -> CGPoint {
            let l = safe.left, r = size.width - safe.right, t = safe.top, b = size.height - safe.bottom
            let x = isLeft ? l : isRight ? r : (l + r) / 2
            return CGPoint(x: x, y: isTop ? t : b)
        }
        /// 중심 위치로 기준점 고르기: 가로 35%·65% 로 셋, 세로 절반으로 둘
        static func nearest(to c: CGPoint, size: CGSize) -> Anchor {
            let top = c.y < size.height * 0.5
            if c.x < size.width * 0.35 { return top ? .topLeft : .bottomLeft }
            if c.x > size.width * 0.65 { return top ? .topRight : .bottomRight }
            return top ? .topCenter : .bottomCenter
        }
    }

    struct Element: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case button, dpad, stick, orb }
        var type: Kind
        /// type == .button. JSON 에는 이름("a","lb",…)으로 쓴다
        var button: PadButton? = nil
        /// type == .stick: "left" | "right"
        var side: String? = nil
        var anchor: Anchor
        var x: Double, y: Double
        /// 배치 포인트. 알약은 반높이, 스틱은 바닥 반지름, 십자키는 반지름
        var radius: Double
        var pill: Bool? = nil, stretch: Double? = nil, label: String? = nil
        /// type == .stick. nil 이면 패드 설정의 "움직이는 스틱"
        var floating: Bool? = nil

        var id: String {
            switch type {
            case .button: return "button." + (button?.name ?? "?")
            case .stick: return "stick." + (side ?? "left")
            case .dpad: return "dpad"
            case .orb: return "orb"
            }
        }
        var isRightStick: Bool { type == .stick && side == "right" }

        /// 화면에 보일 이름 (편집기·접근성)
        var title: String {
            switch type {
            case .button: return (button.map { PadArrangement.buttonTitle($0, label: label) } ?? "?") + " 버튼"
            case .dpad: return "십자키"
            case .stick: return isRightStick ? "오른쪽 스틱" : "왼쪽 스틱"
            case .orb: return "일시정지 버튼"
            }
        }

        /// 편집기 크기 슬라이더 범위 (배치 포인트)
        var radiusRange: ClosedRange<Double> {
            switch type {
            case .button: return pill == true ? 11...28 : 16...44
            case .dpad: return 40...90
            case .stick: return 32...70
            case .orb: return 16...16
            }
        }

        enum CodingKeys: String, CodingKey { case type, button, side, anchor, x, y, radius, pill, stretch, label, floating }

        init(type: Kind, button: PadButton? = nil, side: String? = nil, anchor: Anchor, x: Double, y: Double, radius: Double,
             pill: Bool? = nil, stretch: Double? = nil, label: String? = nil, floating: Bool? = nil) {
            self.type = type; self.button = button; self.side = side; self.anchor = anchor
            self.x = x; self.y = y; self.radius = radius
            self.pill = pill; self.stretch = stretch; self.label = label; self.floating = floating
        }

        /// 틀린 값은 이 요소 전체를 버린다(throw). 숫자는 범위로 자른다
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(Kind.self, forKey: .type)
            anchor = try c.decode(Anchor.self, forKey: .anchor)
            func num(_ k: CodingKeys) throws -> Double {
                let v = try c.decode(Double.self, forKey: k)
                guard v.isFinite else { throw DecodingError.dataCorruptedError(forKey: k, in: c, debugDescription: "not finite") }
                return min(max(v, -4000), 4000)
            }
            x = try num(.x); y = try num(.y)
            switch type {
            case .button:
                guard let name = try c.decodeIfPresent(String.self, forKey: .button), let b = PadButton(name: name), b.onPad else {
                    throw DecodingError.dataCorruptedError(forKey: .button, in: c, debugDescription: "button")
                }
                button = b
                pill = try c.decodeIfPresent(Bool.self, forKey: .pill)
                if let s = try c.decodeIfPresent(Double.self, forKey: .stretch), s.isFinite { stretch = min(max(s, 1), 3) }
                if let l = try c.decodeIfPresent(String.self, forKey: .label) { label = String(l.prefix(8)) }
            case .stick:
                let s = try c.decodeIfPresent(String.self, forKey: .side) ?? "left"
                guard s == "left" || s == "right" else { throw DecodingError.dataCorruptedError(forKey: .side, in: c, debugDescription: "side") }
                side = s
                floating = try c.decodeIfPresent(Bool.self, forKey: .floating)
            case .dpad, .orb: break
            }
            let r = try c.decodeIfPresent(Double.self, forKey: .radius) ?? PadArrangement.defaultRadius(type, button: button)
            radius = r.isFinite ? r : PadArrangement.defaultRadius(type, button: button)
            radius = min(max(radius, 8), 120)
            if type == .orb { radius = 16 }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(type, forKey: .type)
            try c.encodeIfPresent(button?.name, forKey: .button)
            try c.encodeIfPresent(side, forKey: .side)
            try c.encode(anchor, forKey: .anchor)
            // 배치 포인트는 소수 한 자리면 충분하다 (파일이 작아지고 사람이 읽기 쉽게)
            try c.encode((x * 10).rounded() / 10, forKey: .x)
            try c.encode((y * 10).rounded() / 10, forKey: .y)
            if type != .orb { try c.encode((radius * 10).rounded() / 10, forKey: .radius) }
            try c.encodeIfPresent(pill, forKey: .pill)
            try c.encodeIfPresent(stretch, forKey: .stretch)
            try c.encodeIfPresent(label, forKey: .label)
            try c.encodeIfPresent(floating, forKey: .floating)
        }
    }

    var elements: [Element]

    /// 한 배치의 요소 상한 (README "한 종류에 40개 넘는 요소는 거절")
    static let maxElements = 40

    init(elements: [Element]) { self.elements = elements }

    /// 요소 하나가 틀려도 나머지는 읽는다. 같은 요소가 두 번 나오면 뒤의 것. 40개를 넘으면 배치 전체를 버린다
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 요소마다 따로 읽어(LossyElement) 하나가 틀려도 목록 전체가 깨지지 않게 한다
        let list = try c.decode([LossyElement].self, forKey: .elements)
        guard list.count <= Self.maxElements else {
            throw DecodingError.dataCorruptedError(forKey: .elements, in: c, debugDescription: "too many elements \(list.count)")
        }
        var out: [Element] = []
        for item in list {
            guard let e = item.value else { NSLog("[Spoon] 배치 요소 하나를 읽지 못해 뺐어요"); continue }
            out.removeAll { $0.id == e.id }
            out.append(e)
        }
        elements = out
    }
    private struct LossyElement: Decodable {
        var value: Element?
        init(from decoder: Decoder) throws { value = try? Element(from: decoder) }
    }
    enum CodingKeys: String, CodingKey { case elements }

    func element(_ id: String) -> Element? { elements.first { $0.id == id } }

    /// 좌우 거울 (한손 왼손 표시, 편집기 "좌우 뒤집기")
    func mirrored() -> PadArrangement {
        PadArrangement(elements: elements.map { e in
            var m = e; m.anchor = e.anchor.mirrored; m.x = -e.x; return m
        })
    }

    /// 편집기의 "좌우 뒤집기": 거울로 옮기되 어깨 버튼(LB·RB, LT·RT)은 짝의 거울 자리로 가서 L 이 계속 왼쪽에 남는다.
    /// 짝이 없는 어깨 버튼은 제자리
    func flippedForOtherHand() -> PadArrangement {
        let pair: [PadButton: PadButton] = [.lb: .rb, .rb: .lb, .lt: .rt, .rt: .lt]
        let m = mirrored().elements
        return PadArrangement(elements: zip(elements, m).map { e, f in
            guard let b = e.button, let p = pair[b] else { return f }
            var out = e
            if let partner = m.first(where: { $0.button == p }) {
                out.anchor = partner.anchor; out.x = partner.x; out.y = partner.y
            }
            return out
        })
    }

    // MARK: 키

    /// `"<phone|pad>.<landscape|portrait>.<kind>"`. 한손은 가로에서 기본 배치로 그려지므로 가로 키는 기본(simple)과 같다
    static func key(idiom: UIUserInterfaceIdiom, landscape: Bool, kind: PadKind) -> String {
        let k: PadKind = landscape && kind == .oneHand ? .simple : kind
        return "\(idiom == .pad ? "pad" : "phone").\(landscape ? "landscape" : "portrait").\(k.rawValue)"
    }

    /// 읽을 수 있는 키인지 (외부 파일의 키 검사)
    static func isValidKey(_ key: String) -> Bool {
        let p = key.split(separator: ".").map(String.init)
        return p.count == 3 && (p[0] == "phone" || p[0] == "pad") && (p[1] == "landscape" || p[1] == "portrait")
            && PadKind(rawValue: p[2]) != nil
    }

    /// 사람이 읽는 키 이름: "가로 · 기본"
    static func keyTitle(_ key: String) -> String {
        let p = key.split(separator: ".").map(String.init)
        guard p.count == 3 else { return key }
        let dev = p[0] == "pad" ? "iPad" : "iPhone"
        let o = p[1] == "portrait" ? "세로" : "가로"
        let kind = PadKind(rawValue: p[2])?.shortLabel ?? p[2]
        return "\(dev) \(o) · \(kind)"
    }

    // MARK: 기본 값

    /// 기본 반지름 (README): 둥근 버튼 26, 숄더 알약 23, 보기·메뉴 15, 십자키 62, 스틱 48
    static func defaultRadius(_ type: Element.Kind, button: PadButton?) -> Double {
        switch type {
        case .button:
            switch button {
            case .lb?, .rb?, .lt?, .rt?: return 23
            case .view?, .menu?: return 15
            default: return 26
            }
        case .dpad: return 62
        case .stick: return 48
        case .orb: return 16
        }
    }

    static func buttonTitle(_ b: PadButton, label: String?) -> String {
        if let label, !label.isEmpty { return label }
        switch b {
        case .view: return "보기"
        case .menu: return "메뉴"
        default: return b.glyph
        }
    }
}

/// 스킨 zip 의 `layouts.json` (format 1). 편집기 "배치 내보내기"가 쓰는 것과 같다
struct PadArrangementFile: Codable {
    var format: Int
    var layouts: [String: PadArrangement]

    static let maxBytes = 64 * 1024

    /// 크기·형식·키를 검사해 읽는다. 키가 틀리거나 배치가 깨진 것은 그것만 뺀다
    static func parse(_ data: Data) throws -> [String: PadArrangement] {
        guard data.count <= maxBytes else { throw SkinShelf.Rejection(reason: "layouts.json 이 64KB 를 넘어요") }
        struct Raw: Decodable { var format: Int?; var layouts: [String: Lossy]? }
        struct Lossy: Decodable {
            var value: PadArrangement?
            init(from decoder: Decoder) throws { value = try? PadArrangement(from: decoder) }
        }
        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: data) } catch { throw SkinShelf.Rejection(reason: "layouts.json 이 JSON 형식이 아니에요") }
        guard raw.format == 1 else { throw SkinShelf.Rejection(reason: "layouts.json format \(raw.format.map(String.init) ?? "없음") 은 읽을 수 없어요 (1 만 읽어요)") }
        var out: [String: PadArrangement] = [:]
        for (k, v) in raw.layouts ?? [:] {
            guard isValid(key: k), let a = v.value, !a.elements.isEmpty else { NSLog("[Skin] layouts.json \(k.prefix(40)) 무시"); continue }
            out[k] = a
        }
        return out
    }

    private static func isValid(key: String) -> Bool { PadArrangement.isValidKey(key) }

    static func encode(_ layouts: [String: PadArrangement]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(PadArrangementFile(format: 1, layouts: layouts))
    }
}
