import SwiftUI
import WatchKit

/// 버튼판 (design/watch-board.html 9차 C-1 "얼음 단색", 2026-11-09 확정).
/// 208×248pt(46mm) 기준으로 그리고 화면에 맞춰 비율대로 줄인다. 배경은 깊은 남색 라디얼, 버튼은 모두 같은 흰 얼음 유리.
/// 가운데 원반 십자키(네 부채꼴, 원 안에서 미끄러지면 방향만 바뀜) + 귀퉁이 ABXY(원반 쪽을 원의 곡률대로 깎은 둥근 사각) + 좌우 가장자리 세로 −·+.
/// 크라운은 ▲▼: 위로 올리면 ▲, 내리면 ▼ (목록 스크롤과 같은 방향. 실기기에서 반대면 부호 하나만 바꾼다).
struct PadView: View {
    @ObservedObject var link: WatchLink
    @Environment(\.scenePhase) private var scenePhase
    @State private var crown = 0.0
    @State private var crownAccum = 0.0

    /// 설계 기준 크기 (pt)
    private static let design = CGSize(width: 208, height: 248)

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / Self.design.width, geo.size.height / Self.design.height)
            let ox = (geo.size.width - Self.design.width * s) / 2, oy = (geo.size.height - Self.design.height * s) / 2
            ZStack {
                Ice.background.ignoresSafeArea()
                ZStack(alignment: .topLeading) {
                    // 게임 이름 (시계 왼쪽). ● 는 연결 상태색
                    HStack(spacing: 5 * s) {
                        Circle().fill(link.canPlay ? Ice.coral : Color.white.opacity(0.35)).frame(width: 6 * s, height: 6 * s)
                        Text(link.game.isEmpty ? "빙수" : link.game).font(.system(size: 13 * s, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(Ice.text)
                    .offset(x: 12 * s, y: 6 * s)

                    pad(scale: s)
                        .opacity(link.canPlay ? 1 : 0.3)
                        .allowsHitTesting(link.canPlay)
                    if !link.canPlay {
                        Text(link.statusLabel)
                            .font(.system(size: 15 * s, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Ice.text)
                            .shadow(color: .black.opacity(0.9), radius: 10 * s)
                            .frame(width: 160 * s)
                            .position(x: 104 * s, y: 128 * s)
                    }
                }
                .frame(width: Self.design.width * s, height: Self.design.height * s)
                .offset(x: ox, y: oy)
            }
            .animation(.easeOut(duration: 0.2), value: link.canPlay)
        }
        .ignoresSafeArea()
        .focusable()
        .digitalCrownRotation($crown, from: -1000, through: 1000, sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { old, new in
            // 디텐트 한 칸(값 1) 마다 ▲/▼ 한 번. 값이 느는 쪽 = 목록이 아래로 스크롤되는 쪽 = ▼. 빨리 돌리면 칸 수만큼 (연구 P6). 칸마다 시스템 디텐트 톡
            crownAccum += new - old
            while crownAccum >= 1 { crownAccum -= 1; link.tap(.down) }
            while crownAccum <= -1 { crownAccum += 1; link.tap(.up) }
        }
        .onChange(of: scenePhase) { _, p in if p != .active { link.releaseAll() } }
    }

    /// 원반 중심·반지름, ABXY 한 변, 원반과 ABXY 사이 틈 (설계 pt)
    static let discCenter = CGPoint(x: 104, y: 134), discRadius: CGFloat = 70, gem: CGFloat = 60, gap: CGFloat = 10

    /// 버튼들 (설계 좌표 × s)
    @ViewBuilder private func pad(scale s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            DiscPad(link: link, scale: s)
                .frame(width: Self.discRadius * 2 * s, height: Self.discRadius * 2 * s)
                .position(x: Self.discCenter.x * s, y: Self.discCenter.y * s)
            ForEach([(TeaWire.Button.y, 32.0, 62.0), (.x, 176, 62), (.b, 32, 206), (.a, 176, 206)], id: \.0) { b, cx, cy in
                // 원반 중심을 이 버튼의 좌표계로 옮기고, 원반 반지름 + 틈 만큼 깎는다
                GemButton(button: b, link: link, scale: s,
                          cutCenter: CGPoint(x: Self.discCenter.x - (cx - Self.gem / 2), y: Self.discCenter.y - (cy - Self.gem / 2)),
                          cutRadius: Self.discRadius + Self.gap)
                    .frame(width: Self.gem * s, height: Self.gem * s)
                    .position(x: cx * s, y: cy * s)
            }
            // 양쪽 다 길게(0.6초) 누르면 일시정지. 실기기에서 − 를 길게 누르는 사람이 있었다
            EdgeButton(button: .view, link: link, scale: s, longPress: .home).frame(width: 14 * s, height: 44 * s).position(x: 9 * s, y: 134 * s)
            EdgeButton(button: .menu, link: link, scale: s, longPress: .home).frame(width: 14 * s, height: 44 * s).position(x: 199 * s, y: 134 * s)
        }
    }
}

/// 얼음 단색 팔레트 (PLAN 7.6 + 보드 C-1)
enum Ice {
    static let text = Color(red: 0.90, green: 0.93, blue: 0.96)          // #E6ECF5
    static let coral = Color(red: 0.93, green: 0.42, blue: 0.33)         // #EE6A55 연결 점
    static let press = Color(red: 0.43, green: 0.76, blue: 0.91)         // #6EC3E8 눌림 (폰 패드와 같음)
    static let background = RadialGradient(colors: [Color(red: 0.10, green: 0.15, blue: 0.25), Color(red: 0.06, green: 0.09, blue: 0.15), Color(red: 0.03, green: 0.05, blue: 0.08)],
                                           center: UnitPoint(x: 0.5, y: 0.52), startRadius: 0, endRadius: 190)
    /// 돔 유리: 위가 밝은 흰빛 → 아래 옅게, 흰 테두리, 위 하이라이트 선, 아래 그림자
    static func dome<S: InsettableShape>(_ shape: S, pressed: Bool, scale s: CGFloat) -> some View {
        ZStack {
            shape.fill(pressed ? press.opacity(0.85) : Color.clear)
            if !pressed {
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.10)], startPoint: .top, endPoint: .bottom))
                shape.fill(RadialGradient(colors: [.clear, .black.opacity(0.30)], center: .center, startRadius: 20 * s, endRadius: 40 * s))
            } else {
                shape.fill(LinearGradient(colors: [Color.black.opacity(0.18), Color.clear], startPoint: .top, endPoint: .center))
            }
            shape.strokeBorder(Color.white.opacity(pressed ? 0.85 : 0.55), lineWidth: 1)
            if !pressed {
                shape.inset(by: 1.5).strokeBorder(LinearGradient(colors: [Color.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center), lineWidth: 1.2)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 2 * s, y: 1.5 * s)
    }
}

/// 원반 십자키: 네 부채꼴이 ▲▶▼◀. 손가락이 원 안에서 미끄러지면 부채꼴만 바뀌고, 원 밖으로 나가면 뗀 것으로 본다
struct DiscPad: View {
    @ObservedObject var link: WatchLink
    let scale: CGFloat
    @State private var held: TeaWire.Button?

    var body: some View {
        GeometryReader { geo in
            let r = geo.size.width / 2, c = CGPoint(x: r, y: r)
            ZStack {
                Ice.dome(Circle(), pressed: false, scale: scale)
                if let held { wedge(for: held, r: r).fill(Ice.press.opacity(0.72)).clipShape(Circle()) }
                Circle().inset(by: 8 * scale).strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                // 부채꼴 경계 눈금 4개 (테두리 근처만)
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(0.26)).frame(width: 1.5, height: 7 * scale)
                        .offset(y: -(r - 10 * scale)).rotationEffect(.degrees(45 + Double(i) * 90))
                }
                Circle().fill(Color.black.opacity(0.32)).overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1)).frame(width: 18 * scale, height: 18 * scale)
                ForEach(0..<4, id: \.self) { i in
                    Chevron().stroke(Color(red: 0.96, green: 0.98, blue: 0.99), style: StrokeStyle(lineWidth: 2.6 * scale, lineCap: .round, lineJoin: .round))
                        .frame(width: 14 * scale, height: 7 * scale)
                        .offset(y: -(r - 14 * scale)).rotationEffect(.degrees(Double(i) * 90))
                }
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let dx = g.location.x - c.x, dy = g.location.y - c.y
                    let d = hypot(dx, dy)
                    let next: TeaWire.Button?
                    if d > r + 6 * scale || d < 9 * scale { next = nil }          // 원 밖(여유 6pt) 또는 중립
                    else { next = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up) }
                    guard next != held else { return }
                    if let held { link.up(held) }
                    if let next { link.down(next) }
                    held = next
                }
                .onEnded { _ in
                    if let held { link.up(held) }
                    held = nil
                })
        }
    }

    private func wedge(for b: TeaWire.Button, r: CGFloat) -> Path {
        let start: Double = { switch b { case .up: return -135; case .right: return -45; case .down: return 45; default: return 135 } }()
        var p = Path()
        p.move(to: CGPoint(x: r, y: r))
        p.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .degrees(start), endAngle: .degrees(start + 90), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// 꺾쇠 ∧ (위를 가리킴, 회전해서 네 방향)
struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.midX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

/// 둥근 사각에서 원반(+틈)과 겹치는 귀퉁이를 원의 곡률대로 깎은 모양. `cutCenter`·`cutRadius` 는 이 모양의 좌표계 (pt, 이미 s 를 곱한 값)
struct GemShape: InsettableShape {
    var corner: CGFloat
    var cutCenter: CGPoint
    var cutRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let base = Path(roundedRect: r, cornerRadius: max(corner - insetAmount, 0), style: .continuous)
        let cr = cutRadius + insetAmount
        let cut = Path(ellipseIn: CGRect(x: cutCenter.x - cr, y: cutCenter.y - cr, width: cr * 2, height: cr * 2))
        return base.subtracting(cut)
    }

    func inset(by amount: CGFloat) -> GemShape { var s = self; s.insetAmount += amount; return s }
}

/// ABXY: 원반 쪽을 깎은 둥근 사각 얼음 유리. 0.25초 안에 떼면 tap, 넘으면 down → up
struct GemButton: View {
    let button: TeaWire.Button
    @ObservedObject var link: WatchLink
    let scale: CGFloat
    /// 설계 pt (원반 중심을 이 버튼 좌표계로 옮긴 것, 깎는 반지름)
    let cutCenter: CGPoint
    let cutRadius: CGFloat
    @State private var pressing = false
    @State private var sentDown = false
    @State private var holdTimer: Timer?

    var body: some View {
        let shape = GemShape(corner: 22 * scale, cutCenter: CGPoint(x: cutCenter.x * scale, y: cutCenter.y * scale), cutRadius: cutRadius * scale)
        // 글자는 사각 버튼 때처럼 정가운데 (깎인 만큼 밀지 않는다, 2026-11-09 피드백)
        Ice.dome(shape, pressed: pressing, scale: scale)
            .overlay(Text(button.glyph).font(.system(size: 30 * scale, weight: .bold)).foregroundStyle(pressing ? Color(red: 0.04, green: 0.10, blue: 0.16) : .white))
            .scaleEffect(pressing ? 0.97 : 1)
            .contentShape(shape)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true; sentDown = false
                    holdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in sentDown = true; link.down(button) }
                }
                .onEnded { _ in
                    holdTimer?.invalidate(); holdTimer = nil
                    pressing = false
                    if sentDown { link.up(button) } else { link.tap(button) }
                })
    }
}

/// −·+ : 화면 좌우 가장자리의 세로 알약. 누르는 동안 눌림 표시, 0.6초 전에 떼면 그 버튼, 넘기면 `longPress`(⌂ = 일시정지)를 그 순간 보내고 진동.
/// (전에는 onTapGesture + onLongPressGesture 였는데 실기기에서 길게 누르기가 안 먹었다. GemButton 처럼 DragGesture 하나로 통일)
struct EdgeButton: View {
    let button: TeaWire.Button
    @ObservedObject var link: WatchLink
    let scale: CGFloat
    var longPress: TeaWire.Button? = nil
    @State private var pressing = false
    @State private var fired = false
    @State private var holdTimer: Timer?

    var body: some View {
        let shape = Capsule()
        Ice.dome(shape, pressed: pressing, scale: scale)
            .overlay(Text(button == .view ? "−" : "+").font(.system(size: 13 * scale, weight: .bold)).foregroundStyle(pressing ? Color(red: 0.04, green: 0.10, blue: 0.16) : Ice.text))
            .contentShape(shape.inset(by: -6 * scale))   // 가장자리라 닿는 범위를 조금 넓힌다
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true; fired = false
                    if let longPress {
                        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                            fired = true; link.tap(longPress)
                        }
                    }
                }
                .onEnded { _ in
                    holdTimer?.invalidate(); holdTimer = nil
                    pressing = false
                    if !fired { link.tap(button) }
                })
    }
}

/// 연결 상태와 왕복 시간 (연구 P2). 베타 동안만 두 번째 페이지로. "200회 측정" 은 입력 없이 ping 만 보낸다
struct StatsView: View {
    @ObservedObject var link: WatchLink

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                row("세션", link.activated ? "활성" : "비활성")
                row("iPhone", link.reachable ? "닿음" : "안 닿음")
                row("상태", link.state.rawValue + (link.game.isEmpty ? "" : " · \(link.game)"))
                if let s = link.stats {
                    row("횟수", "\(s.count)")
                    row("평균", ms(s.avg)); row("p50", ms(s.p50)); row("p95", ms(s.p95)); row("최대", ms(s.max))
                } else {
                    Text("아직 기록 없음").font(.footnote).foregroundStyle(.secondary)
                }
                row("오류", "\(link.errors)"); row("버림", "\(link.rejected)")
                if !link.lastError.isEmpty { Text(link.lastError).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                Button(link.measuring ? "측정 중…" : "200회 측정") { link.measure() }
                    .disabled(link.measuring || !link.reachable)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ms(_ s: Double) -> String { String(format: "%.0f ms", s * 1000) }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }.font(.footnote)
    }
}
