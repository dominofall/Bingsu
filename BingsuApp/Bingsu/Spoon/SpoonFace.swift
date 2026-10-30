import SwiftUI

/// 가상 패드의 색·재질. 지금은 "얼음 조각" 한 벌(버튼 보드 B3, 2026-10-30 사용자 선택: 흐림 합성이 없어 게임 위에서 발열 비용이 거의 없다).
/// 가상 패드와 일시정지 눈송이 버튼이 같은 값을 써서 한 벌로 보인다. 나중에 패드 스킨은 이 구조체를 채워 끼우면 된다.
struct SpoonSkin {
    var ink = Color.white
    /// 눌렸을 때 채우는 색 (상태색 "원활" 하늘색)
    var press = Color(red: 0.43, green: 0.76, blue: 0.91)
    /// 채움 위(흰빛)·아래(그늘) 진하기 (불투명도 설정 0.25~0.9 에 곱함)
    var fillTop = 0.3, shadeBottom = 0.3
    /// 테두리 진하기
    var rim = 1.1
    var lineWidth: CGFloat = 1

    static let ice = SpoonSkin()
}

extension View {
    /// 패드 버튼·눈송이 버튼 공통 표면: 색 없는 위→아래 그라데이션 하나 + 얇은 흰 테두리 하나. 그 밖의 효과는 넣지 않는다
    func spoonSurface<S: Shape>(_ shape: S, skin: SpoonSkin = .ice, pressed: Bool = false, opacity: Double = 0.6) -> some View {
        background {
            ZStack {
                // 위는 옅은 흰빛, 아래는 옅은 그늘: 밝은 장면(Bingsu)에서도 모양이 보이게
                shape.fill(pressed ? AnyShapeStyle(skin.press.opacity(0.9))
                           : AnyShapeStyle(LinearGradient(colors: [skin.ink.opacity(opacity * skin.fillTop), Color.black.opacity(opacity * skin.shadeBottom)],
                                                           startPoint: .top, endPoint: .bottom)))
                shape.stroke(skin.ink.opacity(min(1, opacity * skin.rim)), lineWidth: skin.lineWidth)
            }
        }
    }
}

/// 가상 패드 그림. 게임 위 오버레이(SpoonOverlay)와 설정 미리보기(SpoonPreview)가 같이 쓴다. 터치는 받지 않는다.
struct SpoonFace: View {
    let layout: SpoonLayout
    let opacity: Double
    let scale: Double
    var skin = SpoonSkin.ice
    var pressed: Set<PadButton> = []
    /// nil 이면 쉬는 자리(미리보기)
    var leftStick: SpoonController.StickState? = nil
    var rightStick: SpoonController.StickState? = nil
    /// 미리보기: 움직이는 스틱 영역을 점선으로
    var showZone = false
    /// 버튼 아래 꼬리표 (이 게임에서의 뜻)
    var tag: (PadButton) -> String? = { _ in nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let s = layout.leftStick { stick(s, state: leftStick) }
            if let s = layout.rightStick { stick(s, state: rightStick) }
            if let c = layout.dpadCenter { dpad(center: c, r: layout.dpadRadius) }
            ForEach(layout.buttons) { button($0) }
        }
        .allowsHitTesting(false)
    }

    private var textColor: Color { skin.ink.opacity(min(1, opacity + 0.4)) }

    private func stick(_ slot: StickSlot, state: SpoonController.StickState?) -> some View {
        let active = state?.active ?? false
        let base = active ? state!.base : slot.restCenter
        let knob = active ? state!.knob : slot.restCenter
        let a = active ? 1 : 0.6
        return ZStack {
            if showZone && slot.floating {
                RoundedRectangle(cornerRadius: 18).fill(skin.ink.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(skin.ink.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                    .frame(width: slot.zone.width, height: slot.zone.height)
                    .position(x: slot.zone.midX, y: slot.zone.midY)
            }
            Color.clear.frame(width: slot.baseRadius * 2, height: slot.baseRadius * 2)
                .spoonSurface(Circle(), skin: skin, opacity: opacity * a * 0.8)
                .position(base)
            Color.clear.frame(width: slot.knobRadius * 2, height: slot.knobRadius * 2)
                .spoonSurface(Circle(), skin: skin, pressed: active, opacity: min(1, opacity + 0.25) * a)
                .position(knob)
        }
    }

    private func dpad(center c: CGPoint, r: CGFloat) -> some View {
        let arm = r * 0.34
        return ZStack {
            ForEach([PadButton.up, .down, .left, .right], id: \.self) { b in
                let on = pressed.contains(b)
                let v: CGSize = b == .up ? CGSize(width: 0, height: -1) : b == .down ? CGSize(width: 0, height: 1)
                    : b == .left ? CGSize(width: -1, height: 0) : CGSize(width: 1, height: 0)
                let len = r - arm
                // 눌린 방향은 그 팔을 하늘색으로 채운다
                if on {
                    RoundedRectangle(cornerRadius: arm * 0.5).fill(skin.press.opacity(0.9))
                        .frame(width: v.width == 0 ? arm * 2 : len, height: v.width == 0 ? len : arm * 2)
                        .offset(x: v.width * (arm + len / 2), y: v.height * (arm + len / 2))
                }
                ArrowShape().fill(on ? Color.white : textColor).shadow(color: .black.opacity(0.35), radius: 1)
                    .frame(width: r * 0.26, height: r * 0.2)
                    .rotationEffect(.degrees(b == .up ? 0 : b == .down ? 180 : b == .left ? -90 : 90))
                    .offset(x: v.width * r * 0.66, y: v.height * r * 0.66)
            }
        }
        .frame(width: r * 2, height: r * 2)
        .spoonSurface(PlusShape(arm: arm / r), skin: skin, opacity: opacity)
        .position(c)
    }

    private func button(_ s: PadButtonSlot) -> some View {
        let on = pressed.contains(s.button)
        let w = s.width, h = s.radius * 2
        let shape = RoundedRectangle(cornerRadius: s.radius, style: .continuous)
        let fontSize = s.pill ? (s.stretch > 1.3 ? 8.5 : 13) * scale : min(s.radius * 0.72, 22 * scale)
        let tagText = tag(s.button)
        return VStack(spacing: 3 * scale) {
            Text(s.glyph)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(on ? Color.white : textColor)
                .shadow(color: .black.opacity(0.35), radius: 1)
                .frame(width: w, height: h)
                .spoonSurface(shape, skin: skin, pressed: on, opacity: opacity)
            if let tagText {
                Text(tagText).font(.system(size: 9.5 * scale, weight: .medium))
                    .foregroundStyle(skin.ink.opacity(min(1, opacity + 0.3)))
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .fixedSize()
            }
        }
        .position(x: s.center.x, y: s.center.y + (tagText != nil ? 7 * scale : 0))
    }
}

/// 십자키 모양 (`arm` = 팔 반폭 / 반지름)
struct PlusShape: Shape {
    var arm: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), R = min(rect.width, rect.height) / 2, a = R * arm
        var p = Path()
        p.addLines([
            CGPoint(x: c.x - a, y: c.y - R), CGPoint(x: c.x + a, y: c.y - R), CGPoint(x: c.x + a, y: c.y - a),
            CGPoint(x: c.x + R, y: c.y - a), CGPoint(x: c.x + R, y: c.y + a), CGPoint(x: c.x + a, y: c.y + a),
            CGPoint(x: c.x + a, y: c.y + R), CGPoint(x: c.x - a, y: c.y + R), CGPoint(x: c.x - a, y: c.y + a),
            CGPoint(x: c.x - R, y: c.y + a), CGPoint(x: c.x - R, y: c.y - a), CGPoint(x: c.x - a, y: c.y - a),
        ])
        p.closeSubpath()
        return p
    }
}

/// 위를 가리키는 작은 삼각형 (십자키 방향 표시)
struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
