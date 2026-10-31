import SwiftUI

/// 가상 패드 그리기. 터치는 SpoonTouchView 가 받고, 그림은 SpoonFace 가 그린다.
struct SpoonOverlay: View {
    @ObservedObject var controller: SpoonController
    /// 전역 또는 게임별로 결정된 패드 설정 (BowlContainerView 가 계산)
    var prefs: PadPrefs = .global()

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let l = SpoonLayout.make(size: full, safe: (insets.top, insets.leading, insets.bottom, insets.trailing),
                                     kind: prefs.kind, scale: prefs.scale, floatingStick: prefs.floatingStick, leftHanded: prefs.leftHanded)
            ZStack(alignment: .topLeading) {
                SpoonFace(layout: l, opacity: prefs.opacity, scale: prefs.scale, pressed: controller.pressed,
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
struct SnowOrb: View {
    var size: CGFloat = 34
    var body: some View {
        SnowflakeShape().stroke(.white, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
            .shadow(color: .black.opacity(0.35), radius: 1)
            .frame(width: size * 0.56, height: size * 0.56)
            .frame(width: size, height: size)
            // 가상 패드 버튼과 같은 표면 (SpoonFinish)
            .spoonSurface(Circle(), opacity: 0.75)
    }
}
