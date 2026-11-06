import SwiftUI

/// 가상 패드 그리기. 터치는 SpoonTouchView 가 받고, 그림은 SpoonFace 가 그린다.
struct SpoonOverlay: View {
    @ObservedObject var controller: SpoonController
    /// 전역 또는 게임별로 결정된 패드 설정 (BowlContainerView 가 계산)
    var prefs: PadPrefs = .global()

    /// 디버그: `BINGSU_PRESS=a,up,lb` 면 그 버튼을 눌린 모양으로 그린다 (스킨 눌림 표시 스크린샷용, 입력은 보내지 않음)
    static let debugPressed: Set<PadButton> = {
        #if DEBUG
        let names = DevEnv["BINGSU_PRESS"]?.split(separator: ",").map(String.init) ?? []
        return Set(names.compactMap { PadButton(name: $0) })
        #else
        return []
        #endif
    }()

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let l = SpoonLayout.make(prefs: prefs, size: full, safe: (insets.top, insets.leading, insets.bottom, insets.trailing))
            ZStack(alignment: .topLeading) {
                SpoonFace(layout: l, opacity: prefs.opacity, scale: prefs.scale, skin: SkinShelf.skin(for: prefs), pressed: controller.pressed.union(Self.debugPressed),
                          leftStick: controller.leftStick, rightStick: controller.rightStick,
                          tag: { b in prefs.showLabels ? controller.cutlery.label(b, mode: controller.mode) : nil })
                SpoonTouchView(controller: controller, layout: l)
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
        }
    }
}

/// 일시정지 버튼 그림: 유리 구슬 속 눈송이 (디자인 보드 5-A 아이콘, 자리는 설정을 따른다)
/// 스킨에 `orb` 그림이 있으면 그 그림, 없으면 스킨 색의 같은 재질. 홈 화면은 얼음 고정
struct SnowOrb: View {
    var size: CGFloat = 34
    var skin: SpoonSkin = .ice
    var body: some View {
        if let p = skin.images["orb"] {
            SkinImage(image: p.normal, width: size, height: size).opacity(0.85)
        } else {
            SnowflakeShape().stroke(skin.textColor, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .shadow(color: .black.opacity(0.35), radius: 1)
                .frame(width: size * 0.56, height: size * 0.56)
                .frame(width: size, height: size)
                // 가상 패드 버튼과 같은 표면
                .spoonSurface(Circle(), skin: skin, opacity: 0.75, fill: skin.fill)
        }
    }
}
