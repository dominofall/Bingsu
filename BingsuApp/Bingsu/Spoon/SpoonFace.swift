import SwiftUI

extension View {
    /// 패드 버튼·눈송이 버튼 공통 표면: (스킨 바탕색) + 위→아래 빛·그늘 그라데이션 하나 + 얇은 테두리 하나. 그 밖의 효과는 넣지 않는다.
    /// `fill`·`pressColor` 는 요소별 값(버튼별 색·십자키·스틱 색). 불투명도 설정은 채움·테두리 전부에 곱한다
    func spoonSurface<S: Shape>(_ shape: S, skin: SpoonSkin = .ice, pressed: Bool = false, opacity: Double = 0.6,
                                fill: Color? = nil, pressColor: Color? = nil) -> some View {
        background {
            ZStack {
                if pressed {
                    shape.fill((pressColor ?? skin.press).opacity(0.9))
                } else {
                    if let fill { shape.fill(fill.opacity(opacity)) }
                    // 위는 옅은 빛, 아래는 옅은 그늘: 밝은 장면(Bingsu)에서도 모양이 보이게
                    shape.fill(LinearGradient(colors: [skin.ink.opacity(opacity * skin.fillTop), skin.shade.opacity(opacity * skin.shadeBottom)],
                                              startPoint: .top, endPoint: .bottom))
                }
                if skin.lineWidth > 0 {
                    shape.stroke(skin.ink.opacity(min(1, opacity * skin.rim)), lineWidth: skin.lineWidth)
                }
            }
        }
    }
}

/// 가상 패드 그림. 게임 위 오버레이(SpoonOverlay)·설정 미리보기(SpoonPreview)·배치 편집기가 같이 쓴다. 터치는 받지 않는다.
/// 스킨에 그림이 있는 요소는 그림만 그리고(눌림은 눌린 그림 또는 press 색 반투명 덧칠), 없는 요소는 색으로 그린다.
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

    private var textColor: Color { skin.textColor.opacity(min(1, opacity + 0.4)) }
    /// 눌린 바탕 위 글자: 밝은 색이면 검게
    private func pressedText(_ fill: Color) -> Color { fill.luminance > 0.82 ? .black : .white }

    private func stick(_ slot: StickSlot, state: SpoonController.StickState?) -> some View {
        let active = state?.active ?? false
        let base = active ? state!.base : slot.restCenter
        let knob = active ? state!.knob : slot.restCenter
        let a = active ? 1 : 0.6
        let fill = skin.stickFill ?? skin.fill
        return ZStack {
            if showZone && slot.floating {
                RoundedRectangle(cornerRadius: 18).fill(skin.ink.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(skin.ink.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                    .frame(width: slot.zone.width, height: slot.zone.height)
                    .position(x: slot.zone.midX, y: slot.zone.midY)
            }
            if let p = skin.images["stick.base"] {
                SkinImage(image: p.normal, width: slot.baseRadius * 2, height: slot.baseRadius * 2)
                    .opacity(min(1, opacity * a * 1.2)).position(base)
            } else {
                Color.clear.frame(width: slot.baseRadius * 2, height: slot.baseRadius * 2)
                    .spoonSurface(Circle(), skin: skin, opacity: opacity * a * 0.8, fill: fill)
                    .position(base)
            }
            if let p = skin.images["stick.knob"] {
                let img = active ? (p.pressed ?? p.normal) : p.normal
                SkinImage(image: img, width: slot.knobRadius * 2, height: slot.knobRadius * 2,
                          pressColor: active && p.pressed == nil ? skin.press : nil)
                    .opacity(min(1, opacity + 0.25) * a).position(knob)
            } else {
                Color.clear.frame(width: slot.knobRadius * 2, height: slot.knobRadius * 2)
                    .spoonSurface(Circle(), skin: skin, pressed: active, opacity: min(1, opacity + 0.25) * a, fill: fill)
                    .position(knob)
            }
        }
    }

    private func dpad(center c: CGPoint, r: CGFloat) -> some View {
        let arm = r * 0.34
        let pic = skin.images["dpad"]
        let dirs: [PadButton] = [.up, .down, .left, .right]
        func vec(_ b: PadButton) -> CGSize {
            b == .up ? CGSize(width: 0, height: -1) : b == .down ? CGSize(width: 0, height: 1)
                : b == .left ? CGSize(width: -1, height: 0) : CGSize(width: 1, height: 0)
        }
        func angle(_ b: PadButton) -> Double { b == .up ? 0 : b == .down ? 180 : b == .left ? -90 : 90 }
        let content = ZStack {
            if let pic { SkinImage(image: pic.normal, width: r * 2, height: r * 2).opacity(opacity) }
            ForEach(dirs, id: \.self) { b in
                let on = pressed.contains(b)
                let v = vec(b)
                let len = r - arm
                if on {
                    if let arm = pic?.pressedArm {
                        // 위쪽 팔이 눌린 그림 하나를 90° 씩 돌려 쓴다
                        SkinImage(image: arm, width: r * 2, height: r * 2).rotationEffect(.degrees(angle(b))).opacity(min(1, opacity + 0.3))
                    } else {
                        // 눌린 방향은 그 팔을 press 색으로 채운다
                        RoundedRectangle(cornerRadius: arm * 0.5).fill(skin.press.opacity(pic == nil ? 0.9 : 0.55))
                            .frame(width: v.width == 0 ? arm * 2 : len, height: v.width == 0 ? len : arm * 2)
                            .offset(x: v.width * (arm + len / 2), y: v.height * (arm + len / 2))
                    }
                }
                if pic?.showsLabel ?? true {
                    ArrowShape().fill(on ? pressedText(skin.press) : textColor).shadow(color: .black.opacity(0.35), radius: 1)
                        .frame(width: r * 0.26, height: r * 0.2)
                        .rotationEffect(.degrees(angle(b)))
                        .offset(x: v.width * r * 0.66, y: v.height * r * 0.66)
                }
            }
        }
        .frame(width: r * 2, height: r * 2)
        return Group {
            if pic != nil { content } else {
                content.spoonSurface(PlusShape(arm: arm / r), skin: skin, opacity: opacity, fill: skin.dpadFill ?? skin.fill)
            }
        }
        .position(c)
    }

    /// 둥근 버튼은 스킨 모양(원·둥근 사각), 알약은 늘 캡슐
    private func shape(_ s: PadButtonSlot) -> AnyShape {
        if !s.pill, case .squircle(let corner) = skin.shape {
            return AnyShape(RoundedRectangle(cornerRadius: s.radius * corner * 2, style: .continuous))
        }
        return AnyShape(RoundedRectangle(cornerRadius: s.radius, style: .continuous))
    }

    private func button(_ s: PadButtonSlot) -> some View {
        let on = pressed.contains(s.button)
        let w = s.width, h = s.radius * 2
        let fontSize = s.pill ? (s.stretch > 1.3 ? 8.5 : 13) * scale : min(s.radius * 0.72, 22 * scale)
        let tagText = tag(s.button)
        let pic = skin.picture(for: s)
        let pressColor = skin.pressFill(for: s.button)
        let glyph = (pic?.showsLabel ?? true) ? skin.glyph(s.button, layoutLabel: s.label) : nil
        let label = Text(glyph ?? "")
            .font(.system(size: fontSize, weight: .bold, design: skin.font))
            .lineLimit(1).minimumScaleFactor(0.45)
            .foregroundStyle(on ? pressedText(pressColor) : textColor)
            .shadow(color: .black.opacity(0.35), radius: 1)
            .padding(.horizontal, s.pill ? 3 : 1)
            .frame(width: w, height: h)
        return VStack(spacing: 3 * scale) {
            if let pic {
                let img = on ? (pic.pressed ?? pic.normal) : pic.normal
                SkinImage(image: img, insets: pic.capInsets, width: w, height: h,
                          pressColor: on && pic.pressed == nil ? pressColor : nil)
                    .opacity(opacity)
                    .overlay { label }
            } else {
                label.spoonSurface(shape(s), skin: skin, pressed: on, opacity: opacity, fill: skin.fill(for: s.button), pressColor: pressColor)
            }
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

/// 스킨 그림 한 장을 w×h 로. `insets`(9-slice, 그림 픽셀)가 있으면 그림 높이를 h 에 맞춘 배율로 감싸 모서리를 늘이지 않고 가운데만 늘인다
/// (디코딩한 CGImage 를 그대로 쓰고 배율만 바꾼 UIImage 를 만들 뿐이라 다시 디코딩하지 않는다).
/// `pressColor` 가 있으면 그림 모양대로 그 색을 반투명하게 덮는다(눌린 그림이 없을 때)
struct SkinImage: View {
    let image: UIImage
    var insets: UIEdgeInsets? = nil
    let width: CGFloat
    let height: CGFloat
    var pressColor: Color? = nil

    var body: some View {
        let img = picture
        img.frame(width: width, height: height)
            .overlay {
                if let pressColor {
                    Rectangle().fill(pressColor.opacity(0.5)).mask(img.frame(width: width, height: height))
                }
            }
    }

    private var picture: Image {
        if let ins = insets, let cg = image.cgImage, height > 0 {
            let s = CGFloat(cg.height) / height
            let ui = UIImage(cgImage: cg, scale: s, orientation: .up)
            return Image(uiImage: ui).resizable(capInsets: EdgeInsets(top: ins.top / s, leading: ins.left / s, bottom: ins.bottom / s, trailing: ins.right / s),
                                                resizingMode: .stretch)
        }
        return Image(uiImage: image).resizable().interpolation(.high)
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
