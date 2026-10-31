import SwiftUI
import SwiftGlass

/// 일시정지 화면. 게임 중에 메뉴를 누르는 이유(패드가 불편함·소리/진동·발열·잠깐 나가기)에 맞춰
/// 목록 대신 그 자리에서 바로 고치는 화면. 가로는 왼쪽 패널이고 오른쪽에 멈춘 게임과 가상 패드가 그대로 보여
/// 바꾼 값이 바로 보인다. 세로는 아래 시트. 패드 값은 이 게임에만 저장하고("모든 게임에 적용" 따로),
/// 진동은 모든 게임 공통 설정이다. 실제 컨트롤러로도 고를 수 있다(`handle(_:)`).
struct PauseBoard: View {
    let dish: Dish
    @ObservedObject var thermometer: Thermometer
    /// 지금 쓰는 패드 설정과, 그 값이 전역 설정을 따르는 중인지
    let pad: PadPrefs
    let padFollowsGlobal: Bool
    /// 패드 값 바꾸기 (이 게임에만 저장)
    let setPad: (PadPrefs) -> Void
    let applyToAllGames: () -> Void
    @Binding var padShown: Bool
    let controllerNames: [String]
    /// 웹 게임만: 초당 프레임·화질 (nil 이면 그 줄을 숨긴다. RPG Maker XP 는 엔진이 정함)
    var fpsLimit: Binding<FpsLimit?>?
    var quality: Binding<Quality?>?
    /// 이번 실행의 화질 (웹뷰를 만들 때 정해짐)
    let runningQuality: Quality
    @Binding var showHUD: Bool
    let lastBackup: Date?
    let onResume: () -> Void
    let onHome: () -> Void
    let onClose: () -> Void
    let onBackup: () -> Void
    let onMoreSettings: () -> Void
    /// 컨트롤러 초점 (BowlContainerView 가 버튼 입력을 넘겨 준다)
    @Binding var focus: PauseItem?

    @AppStorage(Rumble.key) private var rumble = true
    @AppStorage(Rumble.strengthKey) private var rumbleStrength = 0.7
    @AppStorage(Rumble.btSafeKey) private var rumbleBTSafe = true

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let ins = geo.safeAreaInsets
            // iPad 처럼 넓은 화면은 패널을 화면 비율로 키우고 여백·간격도 넉넉하게 (2026-10-30 여백·구분이 부족하다는 의견)
            let wide = min(geo.size.width, geo.size.height) >= 600
            let gap: CGFloat = wide ? 28 : 22
            ZStack(alignment: landscape ? .leading : .bottom) {
                // 패널 밖을 누르면 계속하기. 가로는 게임과 패드가 잘 보이게 아주 옅게
                Color.black.opacity(landscape ? 0.15 : 0.35)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onResume)
                    .accessibilityLabel("계속하기")
                ScrollViewReader { proxy in
                    ScrollView {
                        content(landscape: landscape, wide: wide)
                            .frame(maxWidth: landscape ? .infinity : 640)
                            .frame(maxWidth: .infinity)
                            .padding(.leading, landscape ? ins.leading + gap : max(ins.leading, gap))
                            .padding(.trailing, landscape ? gap : max(ins.trailing, gap))
                            .padding(.top, landscape ? max(ins.top, 14) + gap - 8 : gap + 4)
                            .padding(.bottom, max(ins.bottom, 14) + gap)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: focus) { _, f in
                        guard let f else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(f, anchor: .center) }
                    }
                }
                .frame(width: landscape ? (wide ? min(max(geo.size.width * 0.42, 440), 540) : 370) + ins.leading
                                        : geo.size.width + ins.leading + ins.trailing,
                       height: landscape ? geo.size.height + ins.top + ins.bottom
                                         : min((geo.size.height + ins.bottom) * (wide ? 0.6 : 0.66), wide ? 820 : 640))
                // 유리 패널 (SwiftGlass: iOS 26 은 Liquid Glass). 글자가 읽히도록 카드색을 진하게 섞는다
                .glass(radius: 28, color: Palette.card, colorOpacity: 0.72, material: .regularMaterial,
                       strokeWidth: 1, shadowColor: .black, shadowOpacity: 0.28, shadowRadius: 20, shadowY: 0)
                .transition(.move(edge: landscape ? .leading : .bottom))
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func content(landscape: Bool, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: wide ? 26 : 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(dish.title).font(wide ? .title3.weight(.semibold) : .headline).lineLimit(1)
                    Spacer()
                    chillChip
                }
                Button(action: onResume) {
                    Label("계속하기", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, wide ? 8 : 6)
                }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
                .focusRing(focus == .resume, .capsule).id(PauseItem.resume)
                HStack(spacing: 10) {
                    Button(action: onHome) { Text("홈으로").frame(maxWidth: .infinity).padding(.vertical, 4) }
                        .buttonStyle(.bordered).tint(Palette.accent)
                        .focusRing(focus == .home, .capsule).id(PauseItem.home)
                    Button(role: .destructive, action: onClose) { Text("게임 종료").frame(maxWidth: .infinity).padding(.vertical, 4) }
                        .buttonStyle(.bordered)
                        .focusRing(focus == .close, .capsule).id(PauseItem.close)
                }
            }

            group("조작", wide: wide) {
                HStack(spacing: 6) {
                    ForEach(PadKind.allCases, id: \.self) { k in
                        Button { setPad(with { $0.kind = k }) } label: { PadKindThumb(kind: k, on: pad.kind == k) }
                            .buttonStyle(.plain)
                            .focusRing(focus == .kind(k), .rounded(13)).id(PauseItem.kind(k))
                            .accessibilityLabel("패드 종류 \(k.label)")
                            .accessibilityAddTraits(pad.kind == k ? .isSelected : [])
                    }
                }
                if pad.kind == .oneHand {
                    if landscape { note("한손은 세로로 들었을 때 쓰여요. 가로에서는 기본 배치로 보여요.") }
                    toggle("왼손으로 쓰기", sub: "버튼을 왼쪽 엄지 쪽으로 옮겨요", isOn: Binding(get: { pad.leftHanded }, set: { v in setPad(with { $0.leftHanded = v }) }), item: .leftHand)
                }
                slider("크기", value: pad.scale, in: 0.8...1.3, item: .size) { v in setPad(with { $0.scale = v }) }
                slider("불투명도", value: pad.opacity, in: 0.25...0.9, item: .opacity) { v in setPad(with { $0.opacity = v }) }
                Divider()
                toggle("가상 패드 숨기기", isOn: Binding(get: { !padShown }, set: { padShown = !$0 }), item: .hidePad)
                toggle("버튼 설명 보기", sub: "이 게임에서 각 버튼이 하는 일", isOn: Binding(get: { pad.showLabels }, set: { v in setPad(with { $0.showLabels = v }) }), item: .labels)
                if pad.kind.hasStick {
                    toggle("움직이는 스틱", isOn: Binding(get: { pad.floatingStick }, set: { v in setPad(with { $0.floatingStick = v }) }), item: .floating)
                }
                Divider()
                HStack {
                    Text("컨트롤러").font(.subheadline)
                    Spacer()
                    Text(controllerNames.first ?? "연결 안 됨").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(padFollowsGlobal ? "모든 게임 설정을 쓰는 중이에요. 바꾸면 이 게임에만 저장돼요." : "이 게임에만 적용 중이에요.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if !padFollowsGlobal {
                        Button("모든 게임에 적용", action: applyToAllGames).font(.caption.weight(.semibold))
                            .focusRing(focus == .applyAll, .capsule).id(PauseItem.applyAll)
                    }
                }
            }

            group("소리·진동", wide: wide) {
                toggle("진동", isOn: $rumble, item: .rumble)
                if rumble {
                    slider("세기", value: rumbleStrength, in: 0.1...1, item: .rumbleStrength) { rumbleStrength = $0 }
                    toggle("블루투스 이어폰 보호", sub: "무선 이어폰일 때 진동을 가볍게", isOn: $rumbleBTSafe, item: .btSafe)
                }
                note("진동은 모든 게임에 같이 적용돼요.")
            }

            group("화면·성능", wide: wide) {
                if let fpsLimit {
                    segmented("초당 프레임", item: .fps, options: [(nil, "자동"), (.fps30, "30"), (.fps60, "60")], selection: fpsLimit)
                }
                if let quality {
                    segmented("화질", item: .quality, options: [(nil, "자동"), (.high, "높음"), (.medium, "보통"), (.low, "낮음")], selection: quality)
                    if let q = quality.wrappedValue, q != runningQuality {
                        note("화질은 게임을 다시 열 때 바뀌어요.")
                    }
                }
                toggle("성능 표시", isOn: $showHUD, item: .hud)
            }

            if !dish.isRemote {
                group("저장", wide: wide) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("백업하기").font(.subheadline)
                            Text(lastBackup.map { "마지막 백업 " + $0.formatted(.relative(presentation: .named)) } ?? "아직 백업이 없어요")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("백업", action: onBackup).buttonStyle(.bordered).tint(Palette.accent)
                            .focusRing(focus == .backup, .capsule).id(PauseItem.backup)
                    }
                }
            }

            Button(action: onMoreSettings) {
                HStack { Text("이 게임 설정 더 보기"); Spacer(); Image(systemName: "chevron.right").font(.footnote) }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .font(.subheadline.weight(.medium)).tint(Palette.accent)
            .focusRing(focus == .more, .rounded(20)).id(PauseItem.more)
        }
    }

    /// 묶음 하나: 제목 + 옅은 카드. 묶음끼리 간격과 카드 배경으로 구분한다
    private func group<C: View>(_ title: String, wide: Bool, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.bold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: wide ? 16 : 14) { rows() }
                .padding(wide ? 18 : 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: 조각

    private var chillChip: some View {
        let c = thermometer.chill
        return Text(c.rawValue).font(.caption2.weight(.bold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color(uiColor: c.color), in: Capsule())
            .accessibilityLabel("기기 상태 \(c.rawValue)")
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(.secondary)
    }

    private func with(_ change: (inout PadPrefs) -> Void) -> PadPrefs {
        var p = pad; change(&p); return p
    }

    private func slider(_ title: String, value: Double, in range: ClosedRange<Double>, item: PauseItem,
                        set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
            Text("\(Int((value * 100).rounded()))%").font(.footnote.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        .focusRing(focus == item).id(item)
    }

    private func toggle(_ title: String, sub: String? = nil, isOn: Binding<Bool>, item: PauseItem) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                if let sub { Text(sub).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .tint(Palette.accent)
        .focusRing(focus == item).id(item)
    }

    private func segmented<T: Hashable>(_ title: String, item: PauseItem, options: [(T?, String)], selection: Binding<T?>) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer(minLength: 12)
            Picker(title, selection: selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].1).tag(options[i].0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 190)
        }
        .focusRing(focus == item).id(item)
    }
}

/// 일시정지 화면에서 컨트롤러 초점이 갈 수 있는 것들 (위에서 아래 순서)
enum PauseItem: Hashable {
    case resume, home, close, kind(PadKind), leftHand, size, opacity, hidePad, labels, floating, applyAll
    case rumble, rumbleStrength, btSafe, fps, quality, hud, backup, more
}

/// 패드 종류 고르기 칸 (이름만)
struct PadKindThumb: View {
    let kind: PadKind
    let on: Bool
    var body: some View {
        Text(kind == .oneHand ? "한손" : kind.label)
            .font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            .padding(.vertical, 9).padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .foregroundStyle(on ? Color.white : Palette.syrup)
        .background(on ? Palette.accent : Palette.sky, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// 초점 테두리 모양: 고른 것의 모양을 4pt 바깥으로 따라간다 (캡슐 버튼은 캡슐, 둥근 칸은 반지름 + 4)
private enum RingShape { case capsule, rounded(CGFloat) }

private extension View {
    /// 컨트롤러 초점 테두리
    @ViewBuilder
    func focusRing(_ on: Bool, _ shape: RingShape = .rounded(12)) -> some View {
        switch shape {
        case .capsule:
            overlay(Capsule().strokeBorder(Palette.accent, lineWidth: on ? 2.5 : 0).padding(-4).allowsHitTesting(false))
        case .rounded(let r):
            overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(Palette.accent, lineWidth: on ? 2.5 : 0).padding(-4).allowsHitTesting(false))
        }
    }
}
