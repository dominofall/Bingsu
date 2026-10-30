import SwiftUI
import SwiftGlass
import UniformTypeIdentifiers

struct MenuBoardView: View {
    @EnvironmentObject private var menu: MenuBoardStore
    @ObservedObject private var prefs = DishPrefsStore.shared
    /// 켜 둔 게임. 홈으로 나가면 showBowl 만 false 가 되고 게임은 멈춘 채 살아 있다.
    @State private var running: Dish?
    @State private var showBowl = false
    @State private var showPicker = false
    /// "게임 추가": zip 가져오기 / 주소로 웹 게임 추가 고르기
    @State private var showAddMenu = false
    @State private var showAddWeb = false
    /// "주소로 zip 내려받기" 시트. 내려받기 자체는 Courier 가 맡아 시트를 닫아도 계속된다.
    @ObservedObject private var courier = Courier.shared
    @State private var showDownload = false
    @StateObject private var delivery = Delivery()
    @State private var showDelivery = false
    @State private var showSettings = false
    @State private var editing: Dish?
    /// 길게 눌러 "게임 삭제"를 고른 게임. 알림으로 한 번 더 묻는다
    @State private var deleting: Dish?
    /// 실제 컨트롤러로 게임칩 고르기
    @StateObject private var nav = MenuPadNavigator()
    @State private var gridWidth: CGFloat = 0
    /// 게임칩 "새 버전으로 업데이트"로 파일 선택기를 연 경우 그 게임 id
    @State private var updateTarget: String?
    /// 동기화 충돌: 게임을 열기 전에 어느 저장 데이터로 할지 묻는다
    @State private var conflict: IglooConflict?
    /// iCloud 확인 중인 게임 (두 번 눌러도 한 번만 연다)
    @State private var opening: String?
    @State private var didInitialSync = false
    /// RPG Maker XP 게임은 한 프로세스에 한 번만 켤 수 있어 끝내기 전에 묻는다 (BrassBowl)
    @State private var xpNotice: XPNotice?
    struct XPNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// nil 이면 확인만
        var proceed: (() -> Void)?
    }
    @Environment(\.scenePhase) private var scenePhase

    private let chipMin: CGFloat = 150, chipSpacing: CGFloat = 18
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: chipMin, maximum: UIDevice.current.userInterfaceIdiom == .pad ? 280 : 220), spacing: chipSpacing)] }
    /// 홈이 보이고 시트가 하나도 없을 때만 컨트롤러 입력을 받는다
    private var homeActive: Bool { !showBowl && !showSettings && !showDelivery && !showPicker && !showAddMenu && !showAddWeb && !showDownload && editing == nil && deleting == nil && conflict == nil }
    /// 칩 수 = 게임 수 + "게임 추가" 칩
    private var chipCount: Int { menu.dishes.isEmpty ? 0 : menu.dishes.count + 1 }

    var body: some View {
        ZStack {
            // 게임이 보이는 동안 홈은 그리지 않는다: 큰 흐림 원·리퀴드 글래스가 게임 프레임마다 같이 합성돼 발열을 보탤 수 있음.
            // 없애지 않고 투명하게만 해서 스크롤·초점 상태는 남긴다
            menuBoard
                .opacity(running != nil && showBowl ? 0 : 1)
                .accessibilityHidden(running != nil && showBowl)
            if let dish = running {
                Group {
                    if dish.recipe == .mkxp {
                        BrassBowlContainerView(dish: dish, visible: showBowl, onHome: { wentHome(dish) },
                                               onClose: { running = nil; showBowl = false })
                    } else {
                        BowlContainerView(dish: dish, visible: showBowl, onHome: { wentHome(dish) },
                                          onClose: { running = nil; showBowl = false })
                    }
                }
                .id(dish.id)
                .opacity(showBowl ? 1 : 0)
                .allowsHitTesting(showBowl)
                .zIndex(1)
            }
        }
        .alert(xpNotice?.title ?? "", isPresented: Binding(get: { xpNotice != nil }, set: { if !$0 { xpNotice = nil } }), presenting: xpNotice) { n in
            if let go = n.proceed {
                Button("끝내고 열기", role: .destructive) { go() }
                Button("취소", role: .cancel) {}
            } else {
                Button("확인", role: .cancel) {}
            }
        } message: { n in
            Text(n.message)
        }
    }

    private func wentHome(_ dish: Dish) {
        withAnimation(.easeOut(duration: 0.2)) { showBowl = false }
        if nav.connected { nav.focus = menu.dishes.firstIndex(where: { $0.id == dish.id }) }
    }

    /// RPG Maker XP 엔진은 한 번 끝나면 이번 실행에서 다시 켤 수 없다. 그 때문에 막거나 물어야 하면 true
    private func xpBlocks(_ dish: Dish) -> Bool {
        if dish.recipe == .mkxp, running?.id != dish.id, BrassBowlEngine.shared.hasEnded {
            xpNotice = XPNotice(title: "빙수를 다시 열어 주세요", message: BrassBowlEngine.restartMessage)
            return true
        }
        if let r = running, r.recipe == .mkxp, r.id != dish.id {
            xpNotice = XPNotice(title: "\(r.title) 을(를) 끝낼까요?",
                                message: "다른 게임을 열면 멈춰 둔 RPG Maker XP 게임이 끝나요. 게임 안에서 저장하지 않은 진행은 사라지고, 다시 하려면 빙수를 다시 열어야 해요.",
                                proceed: { running = nil; showBowl = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { serve(dish) } })
            return true
        }
        return false
    }

    /// 게임 열기. 멈춰 둔 게임은 바로 이어 하고, 새로 열 때는 iCloud 에 더 새 저장이 있는지 먼저 본다.
    private func serve(_ dish: Dish) {
        guard dish.recipe.servable else { return }
        if running?.id == dish.id {
            withAnimation(.easeOut(duration: 0.2)) { showBowl = true }
            return
        }
        guard !xpBlocks(dish) else { return }
        guard opening == nil else { return }
        opening = dish.id
        Task {
            let c = await Igloo.shared.prepareOpen(dish)
            opening = nil
            if let c { conflict = c } else { open(dish) }
        }
    }

    private func open(_ dish: Dish) {
        running = dish
        withAnimation(.easeOut(duration: 0.2)) { showBowl = true }
    }

    private var menuBoard: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                if menu.dishes.isEmpty {
                    ContentUnavailableView {
                        Label("아직 게임이 없어요", systemImage: "snowflake")
                    } description: {
                        Text("게임 파일을 가져와 시작해 보세요.")
                    } actions: {
                        Button("게임 추가") { showAddMenu = true }.buttonStyle(.borderedProminent).tint(Palette.accent)
                    }
                    .padding(.top, 80)
                }
                LazyVGrid(columns: columns, spacing: chipSpacing) {
                    ForEach(Array(menu.dishes.enumerated()), id: \.element.id) { i, dish in
                        Button { serve(dish) } label: {
                            GameChip(dish: dish, coverURL: prefs.coverURL(for: dish.id), running: running?.id == dish.id, focused: nav.focus == i)
                        }
                        .buttonStyle(ChipPressStyle())
                        // .disabled 로 막으면 길게 누른 메뉴의 버튼까지 안 눌려 지울 수가 없다 → 흐리게만 하고 serve 에서 거른다
                        .opacity(dish.recipe.servable ? 1 : 0.5)
                        .contextMenu { contextMenu(for: dish) }
                        .id(dish.id)
                    }
                    if !menu.dishes.isEmpty {
                        Button { showAddMenu = true } label: { AddGameChip(focused: nav.focus == menu.dishes.count) }
                            .buttonStyle(ChipPressStyle())
                            .accessibilityLabel("게임 가져오기")
                            .id("add")
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 24)
                .background(GeometryReader { g in Color.clear.onAppear { gridWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in gridWidth = w } })
            }
            .onChange(of: nav.focus) { _, f in
                guard let f else { return }
                let id: String = f < menu.dishes.count ? menu.dishes[f].id : "add"
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
            }
            .background(IceBackground())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if courier.state != .idle { downloadBar }
                    if let dish = running, !showBowl { resumeBar(dish) }
                }
            }
            .navigationTitle("게임 목록")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAddMenu = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("게임 가져오기")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("설정")
                }
            }
            .tint(Palette.accent)
        }
        .confirmationDialog("게임 추가", isPresented: $showAddMenu, titleVisibility: .visible) {
            // iPad 에선 이 대화상자가 팝오버라, 닫히는 도중에 다른 창을 띄우면 그 창이 터치를 못 받는 채로 남는다 → 닫힌 뒤에 띄운다
            Button("zip 파일 가져오기") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showPicker = true } }
            Button("주소로 zip 내려받기") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showDownload = true } }
            Button("주소로 웹 게임 추가") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showAddWeb = true } }
        } message: {
            Text("PC용 게임은 zip 으로, 브라우저 게임은 https 주소로 넣어요. iCloud Drive 의 큰 zip 은 선택한 뒤 내려받는 동안 잠시 멈춘 것처럼 보일 수 있어요.")
        }
        .sheet(isPresented: $showAddWeb) { AddWebGameView().environmentObject(menu) }
        .sheet(isPresented: $showDownload) { DownloadView(courier: courier) }
        // 다 받으면 가져오기로 넘긴다. 앱이 백그라운드였으면 다시 활성화될 때, 게임 중이면 홈으로 나올 때.
        .onChange(of: courier.state, initial: true) { _, _ in importDownloadIfReady() }
        .onChange(of: scenePhase) { _, _ in importDownloadIfReady() }
        .onChange(of: showBowl) { _, _ in importDownloadIfReady() }
        // UIKit 문서 선택기를 창에서 직접 띄운다 (iPad 에서 SwiftUI fileImporter·시트 안 선택기가 멈추는 문제 회피)
        .background(GamePicker(isPresented: $showPicker) { url in
            let target = updateTarget; updateTarget = nil
            if let url { startImport(url, preferring: target) }
        }.frame(width: 0, height: 0))
        .sheet(isPresented: $showSettings) {
            SettingsView(dishes: menu.dishes) { folder in
                if running?.dataPathApp == folder { running = nil; showBowl = false }
            }
        }
        .sheet(item: $conflict) { c in
            ConflictView(conflict: c) { keepLocal in
                Task { await Igloo.shared.resolve(c, keepLocal: keepLocal); open(c.dish) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // 앱이 활성화될 때 iCloud 쪽 확인 (켜 둔 게임은 건너뜀)
            if phase == .active { Task { await Igloo.shared.syncAll(except: Set([running?.dataPathApp].compactMap { $0 })) } }
        }
        .sheet(item: $editing) { dish in DishSettingsView(dish: dish) }
        .alert("‘\(deleting?.title ?? "")’ 게임을 삭제하시겠습니까?",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { dish in
            Button("삭제", role: .destructive) { delete(dish) }
            if !MenuBoardStore.isCustomWeb(dish) {
                Button("저장 데이터까지 삭제", role: .destructive) { delete(dish, saves: true) }
            }
            Button("취소", role: .cancel) {}
        } message: { dish in Text(deleteNote(for: dish)) }
        .sheet(isPresented: $showDelivery) {
            DeliveryView(delivery: delivery, courier: courier, onWillUpdate: { dish in
                // 켜 둔 게임의 파일을 바꾸기 전에 닫는다 (저장 데이터는 닫을 때 파일로 남음)
                if running?.id == dish.id { running = nil; showBowl = false }
            }, onRedownload: {
                // 실패 화면 "주소로 다시 받기"/"이어받기": 가져오기 시트를 닫고 내려받기 시트를 연다
                showDelivery = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showDownload = true }
            }) { _ in showDelivery = false; menu.refresh() }
        }
        .onAppear { wireNavigator() }
        .onChange(of: homeActive) { _, a in nav.active = a }
        .onChange(of: gridWidth) { _, w in
            // 적응형 그리드가 고르는 열 수와 같은 식: (너비 + 간격) / (최소 폭 + 간격)
            nav.columns = max(1, Int(((w - 36) + chipSpacing) / (chipMin + chipSpacing)))
        }
        .onReceive(menu.$dishes) { dishes in
            Igloo.shared.setDishes(dishes)
            if !didInitialSync, !dishes.isEmpty {
                didInitialSync = true
                Task { await Igloo.shared.syncAll(except: Set([running?.dataPathApp].compactMap { $0 })) }
            }
            nav.count = dishes.isEmpty ? 0 : dishes.count + 1
            if let f = nav.focus, f >= nav.count { nav.focus = nav.count > 0 ? nav.count - 1 : nil }
            // 디버그: BINGSU_OPEN=<게임 id> 면 실행 직후 그 게임을 연다
            if running == nil, let id = ProcessInfo.processInfo.environment["BINGSU_OPEN"], let d = dishes.first(where: { $0.id == id }) { serve(d) }
            // 디버그: BINGSU_EDIT=<게임 id> 면 그 게임 설정 시트를 연다 (시뮬레이터 확인용)
            if editing == nil, let id = ProcessInfo.processInfo.environment["BINGSU_EDIT"], let d = dishes.first(where: { $0.id == id }) { editing = d }
        }
        .onChange(of: menu.pendingImport, initial: true) { _, url in
            guard let url else { return }
            menu.pendingImport = nil
            startImport(url)
        }
    }

    /// 홈 아래 "실행 중" 띠: 이어하기 / 종료
    private func resumeBar(_ dish: Dish) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle.fill").font(.title2).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(dish.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("멈춰 있어요").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("종료", role: .destructive) {
                if dish.recipe == .mkxp {
                    xpNotice = XPNotice(title: "\(dish.title) 을(를) 끝낼까요?",
                                        message: "게임 안에서 저장하지 않은 진행은 사라져요. RPG Maker XP 게임은 끝낸 뒤 빙수를 다시 열어야 다시 할 수 있어요.",
                                        proceed: { running = nil })
                } else { running = nil }
            }
                .buttonStyle(.bordered)
            Button("이어하기") { serve(dish) }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassSurface(radius: 22)
        .shadow(color: Palette.accent.opacity(0.18), radius: 14, y: 6)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    /// 홈 아래 "내려받는 중 · 42%" 띠: 누르면 내려받기 시트, 오른쪽에 일시정지/재개
    private var downloadBar: some View {
        HStack(spacing: 12) {
            Button { showDownload = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(courier.fileName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(downloadStatus).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            switch courier.state {
            case .downloading:
                Button { courier.pause() } label: { Image(systemName: "pause.fill") }.buttonStyle(.bordered)
                    .accessibilityLabel("일시정지")
            case .paused:
                Button { courier.resume() } label: { Image(systemName: "play.fill") }.buttonStyle(.borderedProminent).tint(Palette.accent)
                    .accessibilityLabel("재개")
            default: EmptyView()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassSurface(radius: 22)
        .shadow(color: Palette.accent.opacity(0.18), radius: 14, y: 6)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var downloadStatus: String {
        switch courier.state {
        case .checking: return "내려받기 준비 중"
        case .downloading: return "내려받는 중 · \(Int((courier.state.fraction ?? 0) * 100))%"
        case .paused: return "일시정지 · \(Int((courier.state.fraction ?? 0) * 100))%"
        case .failed: return "내려받지 못했어요 · 눌러서 보기"
        case .done: return "다 받았어요 · 가져오는 중"
        case .idle: return ""
        }
    }

    /// 다 받은 파일을 가져오기로 넘긴다. 앱이 보이고, 게임 중이 아니고, 다른 가져오기가 없을 때만.
    private func importDownloadIfReady() {
        guard case .done(let file) = courier.state, scenePhase == .active, !showBowl, !delivery.stage.isBusy else { return }
        NSLog("[Courier] handing off to import")
        courier.handedOff()
        let wasOpen = showDownload
        showDownload = false
        // 내려받기 시트가 닫히는 중에 가져오기 시트를 올리면 무시될 수 있어 한 박자 쉰다 (startImport 도 0.35초 기다림)
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasOpen ? 0.3 : 0)) { startImport(file) }
    }

    /// 컨트롤러 탐색기 연결: A = 열기(게임 추가 칩이면 가져오기), 메뉴 = 설정
    private func wireNavigator() {
        nav.active = homeActive
        nav.count = chipCount
        nav.onSelect = { i in
            if i < menu.dishes.count {
                let d = menu.dishes[i]
                if d.recipe.servable { serve(d) }
            } else {
                showAddMenu = true
            }
        }
        nav.onSettings = { showSettings = true }
    }

    private func startImport(_ url: URL, preferring targetID: String? = nil) {
        // 이미 가져오는 중이면 새 파일은 무시하고 진행 화면만 다시 보여 준다
        if !delivery.stage.isBusy { delivery.start(from: url, preferring: targetID) }
        // iPad 에선 파일 선택기가 닫히는 중에 시트를 올리면 무시될 때가 있어 한 박자 뒤에 올린다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showDelivery = true }
    }

    @ViewBuilder
    private func contextMenu(for dish: Dish) -> some View {
        Button { editing = dish } label: { Label("이 게임 설정", systemImage: "slider.horizontal.3") }
        if !dish.isRemote && !MenuBoardStore.isBuiltIn(dish) {
            Button { updateTarget = dish.id; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showPicker = true } } label: { Label("새 버전으로 업데이트", systemImage: "arrow.down.circle") }
        }
        if MenuBoardStore.isCustomWeb(dish) || (!dish.isRemote && !MenuBoardStore.isBuiltIn(dish)) {
            // 메뉴가 닫힌 뒤에 알림을 띄운다 (닫히는 중에 띄우면 iPad 에서 무시될 때가 있다)
            Button(role: .destructive) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { deleting = dish } } label: {
                Label("게임 삭제", systemImage: "trash")
            }
        }
    }

    /// 삭제 확인 알림의 설명. 가져온 게임은 저장 데이터를 남기고, 웹 게임은 그 사이트의 로그인·진행도까지 지운다
    private func deleteNote(for dish: Dish) -> String {
        MenuBoardStore.isCustomWeb(dish)
            ? "이 웹 게임의 로그인 정보와 진행도도 함께 지워져요."
            : "\"삭제\"는 게임 파일만 지워요. 저장 데이터는 남아 있어 다시 가져오면 이어서 할 수 있고, 설정 › 저장 데이터 관리에서 따로 지울 수 있어요. \"저장 데이터까지 삭제\"는 iCloud 사본과 백업까지 모두 지워요."
    }

    private func delete(_ dish: Dish, saves: Bool = false) {
        if running?.id == dish.id { running = nil; showBowl = false }
        let before = menu.dishes   // 지우기 전 목록 (웹 저장소를 찾을 때 이 게임도 들어 있어야 한다)
        if MenuBoardStore.isCustomWeb(dish) { menu.removeWebGame(dish) } else { menu.remove(dish) }
        prefs.remove(dish.id)
        // "따로 하나 더 추가"한 사본이 같은 저장 폴더를 쓰면 저장 데이터는 남긴다
        if saves, !menu.dishes.contains(where: { $0.dataPathApp == dish.dataPathApp }) {
            Task { await FreezerShelf.wipe(folder: dish.dataPathApp, dishes: before) }
        }
    }
}

/// 컨트롤러 초점: 게임칩의 유리 테두리가 파랗게 한 바퀴 채워진다. 표지 테두리에만 그려 아래 제목을 가리지 않는다
struct FocusFill: View {
    let radius: CGFloat
    let on: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.inset(by: 2)
            .trim(from: 0, to: on ? 1 : 0)
            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .shadow(color: Palette.accent.opacity(on ? 0.6 : 0), radius: 6)
            .animation(on ? .easeOut(duration: 0.35) : .easeIn(duration: 0.12), value: on)
            .allowsHitTesting(false)
    }
}

/// 누르면 살짝 눌리는 게임칩 버튼
struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 게임칩 표지: 사용자가 고른 이미지, 기본 게임의 번들 표지, 또는 기본 그라데이션 + 아이콘. 위에 얼음 광택.
struct GameChipCover: View {
    let dish: Dish
    let coverURL: URL?

    var body: some View {
        ZStack {
            if let coverURL, let ui = UIImage(contentsOfFile: coverURL.path) {
                Color.clear.overlay(Image(uiImage: ui).resizable().scaledToFill())
            } else if MenuBoardStore.isBuiltIn(dish),
                      let ui = UIImage(contentsOfFile: dish.location.appendingPathComponent("cover.png").path) {
                // 기본 게임은 번들에 든 픽셀 표지(SampleGame/cover.png)를 기본 표지로. 픽셀이 번지지 않게 보간 없이 키운다
                Color.clear.overlay(Image(uiImage: ui).resizable().interpolation(.none).scaledToFill())
            } else {
                LinearGradient(colors: [Palette.sky, Palette.card, Palette.sky.opacity(0.7)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: dish.isRemote ? "globe" : "gamecontroller.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Palette.accent.opacity(0.85))
            }
            // 얼음 광택: 왼쪽 위에서 비치는 흰 빛
            LinearGradient(stops: [.init(color: .white.opacity(0.45), location: 0), .init(color: .white.opacity(0.08), location: 0.35),
                                   .init(color: .clear, location: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .blendMode(.screen)
        }
        .clipped()
    }
}

/// 게임칩 (디자인 보드 칩 2, 2026-10-30 사용자 선택): 표지는 깨끗하게, 제목·상태는 표지 아래.
/// 표지 테두리는 두께가 느껴지는 유리 테두리. 실행 중이면 파란 테두리와 코랄 점.
struct GameChip: View {
    let dish: Dish
    let coverURL: URL?
    var running = false
    /// 컨트롤러 초점
    var focused = false

    static let radius: CGFloat = 22
    /// 유리 틀 두께
    static let rim: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 표지를 두께 있는 유리 틀(SwiftGlass, iOS 26 은 Liquid Glass) 안에 끼운다
            GameChipCover(dish: dish, coverURL: coverURL)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Self.radius - Self.rim, style: .continuous))
                .overlay(GlassRim(radius: Self.radius - Self.rim, running: running))
                .padding(Self.rim)
                .glass(radius: Self.radius, color: Palette.accent, colorOpacity: 0.08, material: .ultraThinMaterial,
                       strokeWidth: 1.5, shadowColor: Palette.accent, shadowOpacity: 0.22, shadowRadius: 12, shadowY: 6)
                .overlay(FocusFill(radius: Self.radius, on: focused))
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(dish.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text(running ? "실행 중 · 이어하기" : dish.isRemote ? "웹 게임" : (dish.recipe.unservableNote ?? "설치됨"))
                        .font(.caption2).foregroundStyle(running ? Palette.accent : .secondary)
                }
                Spacer(minLength: 0)
                if running {
                    Circle().fill(Palette.ribbon).frame(width: 9, height: 9).padding(.top, 5)
                }
            }
            .padding(.horizontal, 2)
        }
        .opacity(dish.recipe.servable ? 1 : 0.55)
    }
}

/// 유리 테두리: 왼쪽 위는 빛을 받아 밝고 오른쪽 아래는 그릇 파랑이 비치는 굵은 테두리 + 안쪽 가는 선(유리 두께)
struct GlassRim: View {
    let radius: CGFloat
    var running = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.35), Palette.accent.opacity(0.4)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.5)
            shape.inset(by: 3).strokeBorder(.white.opacity(0.3), lineWidth: 0.8)
            shape.stroke(Palette.syrup.opacity(0.12), lineWidth: 0.5)
            if running { shape.strokeBorder(Palette.accent, lineWidth: 3) }
        }
        .allowsHitTesting(false)
    }
}

/// 목록 끝의 빈 게임칩: 누르면 게임 가져오기
struct AddGameChip: View {
    var focused = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 30, weight: .medium)).foregroundStyle(Palette.accent)
                Text("게임 추가").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(Palette.card.opacity(0.5), in: RoundedRectangle(cornerRadius: GameChip.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GameChip.radius, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [8, 7])))
            .overlay(FocusFill(radius: GameChip.radius, on: focused))
            Text("zip 파일 또는 웹 주소").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 2)
        }
    }
}
