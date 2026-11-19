import SwiftUI
import SwiftGlass
import GameController

/// 일시정지 화면. 게임 중에 메뉴를 누르는 이유(패드가 불편함·소리/진동·발열·잠깐 나가기)에 맞춰
/// 목록 대신 그 자리에서 바로 고치는 화면. 가로는 왼쪽 패널이고 오른쪽에 멈춘 게임과 가상 패드가 그대로 보여
/// 바꾼 값이 바로 보인다. 세로는 아래 시트. 패드 값은 이 게임에만 저장하고("모든 게임에 적용" 따로),
/// 진동은 모든 게임 공통 설정이다. 실제 컨트롤러로도 고를 수 있다(`handle(_:)`).
struct PauseBoard: View {
    let dish: Dish
    /// 주소로 넣은 게임만: 지금 게임 화면의 실제 주소 (페이지가 빙수 화면을 흉내 내도 여기서 진짜 사이트를 확인한다, 보안 3차)
    var pageURL: URL? = nil
    @ObservedObject var thermometer: Thermometer
    /// 지금 쓰는 패드 설정과, 그 값이 전역 설정을 따르는 중인지
    let pad: PadPrefs
    let padFollowsGlobal: Bool
    /// 패드 값 바꾸기 (이 게임에만 저장)
    let setPad: (PadPrefs) -> Void
    let applyToAllGames: () -> Void
    @Binding var padShown: Bool
    /// 새 모양 Electron 게임만: 키보드 키 줄 보기 (nil 이면 그 줄을 숨긴다, 터치 조작 §8)
    var keyStrip: Binding<Bool>? = nil
    let controllerNames: [String]
    /// 웹 게임만: 초당 프레임·화질 (nil 이면 그 줄을 숨긴다. RPG Maker XP 는 엔진이 정함)
    var fpsLimit: Binding<FpsLimit?>?
    var quality: Binding<Quality?>?
    /// 포켓로그만: 배경음악 음질 (nil 이면 그 줄을 숨긴다)
    var musicRate: Binding<MusicRate?>? = nil
    /// 이번 실행의 화질 (웹뷰를 만들 때 정해짐)
    let runningQuality: Quality
    @Binding var showHUD: Bool
    let onResume: () -> Void
    let onHome: () -> Void
    let onClose: () -> Void
    let onMoreSettings: () -> Void
    /// 저장 묶음 (빌드 50: 가장 최근 저장 카드 · 저장 · 불러오기). 상태 저장을 지원하는 게임만, nil 이면 묶음을 숨긴다
    /// 저장: 바로 새 칸에. 불러오기: 칸 목록(불러오기·이름 바꾸기·지우기)
    var onSave: (() -> Void)? = nil
    var onLoad: (() -> Void)? = nil
    /// 가장 최근 저장 칸 (자동 저장·예전 빠른 저장 포함)과 저장된 칸 수
    var latestSave: Scoop.Entry? = nil
    var saveCount: Int = 0
    /// "배치 편집" (이 게임에 저장). nil 이면 숨김
    var onEditLayout: (() -> Void)? = nil
    /// "가상 키보드 열기" (게임 키보드로 바꾸기, RPG Maker 게임). nil 이면 숨김
    var onKeyboard: (() -> Void)? = nil
    /// "카메라 피하기" 줄 (iPhone Duo 에서만)
    var showsCameraOption = false
    /// 컨트롤러 초점 (BowlContainerView 가 버튼 입력을 넘겨 준다)
    @Binding var focus: PauseItem?

    @AppStorage(BingsuApp.gameVolumeKey) private var gameVolume = 1.0
    @AppStorage(BingsuApp.playInSilentKey) private var globalPlayInSilent = false
    @ObservedObject private var prefsStore = DishPrefsStore.shared
    @AppStorage(GameFrame.avoidCameraKey) private var avoidCamera = false
    @AppStorage(Rumble.key) private var rumble = true
    @AppStorage(Rumble.strengthKey) private var rumbleStrength = 0.7
    @AppStorage(Rumble.btSafeKey) private var rumbleBTSafe = true
    @ObservedObject private var keyCapture = KeyCapture.shared
    /// 컨트롤러·키보드 연결 (연결됐을 때만 "컨트롤러·키보드" 묶음을 보인다)
    @State private var keyboardOn = KeyCapture.keyboardConnected
    private var hasInput: Bool { !controllerNames.isEmpty || keyboardOn || KeyCapture.controllerConnected }
    private var inputNames: String {
        let names = controllerNames + (keyboardOn ? ["키보드"] : [])
        return names.isEmpty ? "컨트롤러" : names.joined(separator: " · ")
    }

    @ObservedObject private var hinge = HingeStore.shared

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let ins = geo.safeAreaInsets
            // iPad 처럼 넓은 화면은 패널을 화면 비율로 키우고 여백·간격도 넉넉하게 (2026-10-30 여백·구분이 부족하다는 의견)
            let wide = min(geo.size.width, geo.size.height) >= 600
            let gap: CGFloat = wide ? 28 : 22
            // 반 접기(노트북 모양): 접히는 선을 넘지 않게 아래 절반에만 (경첩 위 글자는 읽기도 누르기도 힘들다)
            let full = CGSize(width: geo.size.width + ins.leading + ins.trailing, height: geo.size.height + ins.top + ins.bottom)
            let fold = hinge.pose.halfFoldLine(size: full, insets: GameFrame.windowInsets())
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
                // 가로 폭이 좁은 화면(iPhone Duo 바깥 화면 678pt 등)은 패널을 줄여 게임이 반 넘게 보이게
                .frame(width: landscape ? (wide ? min(max(geo.size.width * 0.42, 440), 540)
                                                : (geo.size.width + ins.leading + ins.trailing < 760 ? 350 : 370)) + ins.leading
                                        : geo.size.width + ins.leading + ins.trailing,
                       height: landscape ? geo.size.height + ins.top + ins.bottom
                                         : fold.map { full.height - $0 - 10 }
                                         ?? min((geo.size.height + ins.bottom) * (wide ? 0.6 : 0.66), wide ? 820 : 640))
                // 유리 패널 (SwiftGlass: iOS 26 은 Liquid Glass). 글자가 읽히도록 카드색을 진하게 섞는다
                .glass(radius: 28, color: Palette.card, colorOpacity: 0.72, material: .regularMaterial,
                       strokeWidth: 1, shadowColor: .black, shadowOpacity: 0.28, shadowRadius: 20, shadowY: 0)
                .transition(.move(edge: landscape ? .leading : .bottom))
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(get: { keyCapture.presentFor == dish.id }, set: { if !$0 { keyCapture.presentFor = nil } })) {
            InputView(dish: dish, asSheet: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in keyboardOn = KeyCapture.keyboardConnected }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in keyboardOn = KeyCapture.keyboardConnected }
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
                if let url = pageURL, let host = url.host, !host.isEmpty {
                    let secure = url.scheme?.lowercased() == "https"
                    Label(host, systemImage: secure ? "lock.fill" : "lock.open.fill")
                        .font(.footnote).foregroundStyle(secure ? Color.secondary : Color.orange)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityLabel("지금 주소 \(host)" + (secure ? "" : ", 암호화 안 됨"))
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
                // Duo: 게임이 카메라에 가리면 바로 끄고 켜도록 계속하기 바로 아래 (사용자 2026-11-18)
                if showsCameraOption && GameFrame.isDuo {
                    toggle("카메라 피하기", sub: "iPhone Duo 바깥 화면에서 게임이 카메라에 가리지 않게 조금 작아져요", isOn: $avoidCamera, item: .avoidCamera)
                }
                // 이름 입력처럼 지금 막힌 일을 푸는 버튼이라 조작 묶음보다 위에
                if let onKeyboard {
                    Button(action: onKeyboard) {
                        HStack { Label("가상 키보드 열기", systemImage: "keyboard"); Spacer(); Image(systemName: "chevron.right").font(.footnote) }
                            .font(.subheadline)
                    }
                    .tint(Palette.accent)
                    .focusRing(focus == .keyboard).id(PauseItem.keyboard)
                }
            }

            // 게임 중 가장 자주 누르는 일이라 계속하기·홈으로 바로 아래 (사용자 2026-11-17)
            if let onSave, let onLoad {
                group("저장", wide: wide) { saveRows(save: onSave, load: onLoad) }
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
                if let keyStrip {
                    toggle("키보드 키", sub: "Esc·Enter 같은 키를 화면에 띄워요. 가상 패드가 보이면 숨어요", isOn: keyStrip, item: .keyStrip)
                }
                toggle("버튼 설명 보기", sub: "이 게임에서 각 버튼이 하는 일", isOn: Binding(get: { pad.showLabels }, set: { v in setPad(with { $0.showLabels = v }) }), item: .labels)
                if pad.providesStick() {
                    toggle("움직이는 스틱", isOn: Binding(get: { pad.floatingStick }, set: { v in setPad(with { $0.floatingStick = v }) }), item: .floating)
                }
                if let onEditLayout {
                    Button(action: onEditLayout) {
                        HStack { Label("배치 편집", systemImage: "hand.draw"); Spacer(); Image(systemName: "chevron.right").font(.footnote) }
                            .font(.subheadline)
                    }
                    .tint(Palette.accent)
                    .focusRing(focus == .editLayout).id(PauseItem.editLayout)
                }
                SkinPicker(prefs: Binding(get: { pad }, set: { setPad($0) }), showsManage: false, compact: true)
                    .accessibilityLabel("스킨")
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
                slider("소리 크기", value: gameVolume, in: 0...1, item: .volume) { BingsuApp.setGameVolume($0) }
                if let musicRate {
                    segmented("배경음악 음질", item: .musicRate, options: MusicRate.allCases.map { ($0, $0.label) },
                              selection: Binding(get: { musicRate.wrappedValue ?? .default }, set: { musicRate.wrappedValue = $0 }))
                    note("낮출수록 오래 해도 게임이 덜 다시 불러와져요. 새로 나오는 곡부터 바뀌어요.")
                }
                // 2026-11-01 사용자 요청: 게임하면서 다른 앱 영상을 같이 보기. "무음 모드에서도 소리 재생"(이 게임)의 반대
                toggle("다른 앱 소리와 함께 듣기", sub: "영상·음악 앱과 같이 들려요. 무음 모드면 게임 소리는 꺼져요",
                       isOn: Binding(get: { _ = globalPlayInSilent; _ = prefsStore.prefs(for: dish.id); return !BingsuApp.playInSilent(for: dish.id) },
                                     set: { BingsuApp.setPlayInSilent(!$0, for: dish.id) }),
                       item: .mixAudio)
                toggle("진동", isOn: $rumble, item: .rumble)
                if rumble {
                    slider("세기", value: rumbleStrength, in: 0.1...1, item: .rumbleStrength) { rumbleStrength = $0 }
                    toggle("블루투스 이어폰 보호", sub: "무선 이어폰일 때 진동을 가볍게", isOn: $rumbleBTSafe, item: .btSafe)
                }
                note("소리 크기와 진동은 모든 게임에, 다른 앱 소리와 함께 듣기는 이 게임에만 적용돼요.")
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

            // 키 설정은 미리 한 번 해 두는 일이라 아래에. 컨트롤러나 키보드가 연결됐을 때만
            if hasInput {
                Button { keyCapture.presentFor = dish.id } label: {
                    HStack {
                        Label("컨트롤러·키보드", systemImage: "gamecontroller")
                        Spacer(minLength: 8)
                        Text(inputNames).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.footnote)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .font(.subheadline.weight(.medium)).tint(Palette.accent)
                .focusRing(focus == .keyMap, .rounded(20)).id(PauseItem.keyMap)
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

    // MARK: 저장 (빌드 50)

    /// 가장 최근 저장 카드 + [저장] [불러오기 N개] (사용자 2026-11-18: 빠른 저장·상태 저장·백업을 이 셋으로)
    private func saveRows(save: @escaping () -> Void, load: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let e = latestSave, let name = Scoop.fileName(dish, e.slot) {
                SaveCardView(dish: dish, fileName: name, date: e.date, name: e.name)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "photo").font(.title3).foregroundStyle(.secondary)
                        .frame(width: 104, height: 78)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("아직 저장한 게 없어요").font(.subheadline.weight(.semibold))
                        Text("맵에서 자유롭게 움직일 수 있을 때 저장돼요").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                Button(action: save) {
                    Label("저장", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
                .focusRing(focus == .save, .capsule).id(PauseItem.save)
                Button(action: load) {
                    HStack(spacing: 6) {
                        Label("불러오기", systemImage: "arrow.uturn.backward")
                        if saveCount > 0 { Text("\(saveCount)").font(.footnote.weight(.bold)).monospacedDigit().opacity(0.7) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered).tint(Palette.accent)
                .focusRing(focus == .load, .capsule).id(PauseItem.load)
                .accessibilityLabel("불러오기, 저장 \(saveCount)개")
            }
            .font(.subheadline.weight(.semibold))
            .buttonBorderShape(.capsule)
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
            Text(title).font(.subheadline).lineLimit(1).fixedSize().frame(minWidth: 64, alignment: .leading)
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
    case resume, home, close, avoidCamera, save, load, kind(PadKind), editLayout, keyboard, keyMap, leftHand, size, opacity, hidePad, keyStrip, labels, floating, applyAll
    case volume, musicRate, mixAudio, rumble, rumbleStrength, btSafe, fps, quality, hud, more
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
