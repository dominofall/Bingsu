import SwiftUI

/// 리퀴드 글래스 공용 모디파이어
struct GlassSurface: ViewModifier {
    var radius: CGFloat = 20
    var tinted = false

    func body(content: Content) -> some View {
        content.glassEffect(tinted ? .regular.tint(Palette.accent.opacity(0.35)) : .regular,
                            in: .rect(cornerRadius: radius))
    }
}

extension View {
    func glassSurface(radius: CGFloat = 20, tinted: Bool = false) -> some View {
        modifier(GlassSurface(radius: radius, tinted: tinted))
    }
}

/// 홈 바탕 (디자인 보드 7-B, 2026-10-30 사용자 선택): 위는 하늘빛, 아래로 회색. 아주 옅은 눈 결정이 흩어져 있다.
/// 흐림 효과 없이 그라데이션과 선만 써서 가볍다.
struct IceBackground: View {
    @Environment(\.colorScheme) private var scheme

    /// 눈 결정 자리(화면 비율)와 크기(iPhone 폭 기준 pt)
    private static let flakes: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (0.10, 0.18, 9), (0.84, 0.14, 7), (0.53, 0.30, 6), (0.15, 0.49, 8), (0.89, 0.45, 10), (0.46, 0.66, 7),
        (0.81, 0.75, 8), (0.10, 0.85, 6), (0.64, 0.94, 9), (0.31, 0.35, 5), (0.74, 0.59, 6),
    ]

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(stops: dark
                           ? [.init(color: Color(red: 0.11, green: 0.16, blue: 0.27), location: 0),
                              .init(color: Color(red: 0.07, green: 0.11, blue: 0.17), location: 0.38),
                              .init(color: Color(red: 0.06, green: 0.08, blue: 0.13), location: 0.7)]
                           : [.init(color: Color(red: 0.85, green: 0.91, blue: 0.98), location: 0),
                              .init(color: Color(red: 0.91, green: 0.94, blue: 0.97), location: 0.38),
                              .init(color: Color(red: 0.93, green: 0.94, blue: 0.95), location: 0.7)],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { geo in
                let k = min(2, max(1, min(geo.size.width, geo.size.height) / 393))
                ForEach(Self.flakes.indices, id: \.self) { i in
                    let f = Self.flakes[i]
                    SnowflakeShape()
                        .stroke(Palette.accent.opacity(dark ? 0.2 : 0.14), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                        .frame(width: f.size * 2 * k, height: f.size * 2 * k)
                        .position(x: geo.size.width * f.x, y: geo.size.height * f.y)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// 눈송이: 여섯 갈래에 갈래마다 작은 가지 둘. 일시정지 버튼과 홈 바탕이 같이 쓴다.
struct SnowflakeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 - .pi / 2
            p.move(to: c)
            p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
            let b = CGPoint(x: c.x + cos(a) * r * 0.6, y: c.y + sin(a) * r * 0.6)
            for d: CGFloat in [-0.7, 0.7] {
                p.move(to: b)
                p.addLine(to: CGPoint(x: b.x + cos(a + d) * r * 0.32, y: b.y + sin(a + d) * r * 0.32))
            }
        }
        return p
    }
}
