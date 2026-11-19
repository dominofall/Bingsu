import SwiftUI

/// 불러오기 목록 (일시정지 › 불러오기, 빌드 49 상태 저장 목록 → 빌드 50).
/// 칸들(최근이 위): 사진 · 시각 · 이름. 자동 저장·예전 빠른 저장 칸도 함께 보인다. 새 칸 저장은 일시정지 화면의 [저장] 이 한다.
/// 칸 누르기 → 확인 → 불러오기. "편집" → 칸마다 덮어쓰기·이름 바꾸기·지우기 버튼. 길게 누르기·밀기로도 된다.
/// 컨트롤러: 위·아래 고르기, A 불러오기, Y 칸 메뉴(왼·오른쪽으로 고르고 A), B 닫기. 확인 창은 A 확인·B 취소
@MainActor
final class ScoopList: ObservableObject {
    let dish: Dish
    @Published var entries: [Scoop.Entry] = []
    /// 컨트롤러 초점: 고른 칸 (nil = 아직 안 고름)
    @Published var focus: Scoop.Slot?
    @Published var controllerFocus = false
    /// 컨트롤러 칸 메뉴가 열린 칸과 고른 일
    @Published var menuFor: Scoop.Slot?
    @Published var menuChoice = 0
    @Published var confirmLoad: Scoop.Entry?
    @Published var confirmDelete: Scoop.Entry?
    @Published var confirmOverwrite: Scoop.Entry?
    @Published var renaming: Scoop.Entry?
    @Published var renameText = ""
    @Published var full = false
    /// 편집: 칸마다 덮어쓰기·이름 바꾸기·지우기 버튼을 펼친다 (칸을 눌러도 불러오지 않는다)
    @Published var editing = false

    /// 저장(새 칸·덮어쓰기)과 불러오기는 게임 화면이 한다 (시트·일시정지를 닫고 게임의 저장 코드로)
    var onSave: (Scoop.Slot) -> Void = { _ in }
    var onLoad: (Scoop.Slot) -> Void = { _ in }
    var onClose: () -> Void = {}

    init(dish: Dish) { self.dish = dish }

    func reload() {
        ScoopShelf.movePhotos(dish)
        SaveCard.ingest(dish)
        entries = Scoop.entries(dish)
        if let f = focus, !entries.contains(where: { $0.slot == f }) { focus = nil }
    }

    var stateCount: Int { entries.filter { if case .state = $0.slot { return true }; return false }.count }

    func saveNew() {
        guard let slot = Scoop.freeState(dish) else {
            NSLog("[Scoop] 상태 저장 칸이 가득 참 (\(Scoop.maxStates))")
            full = true
            return
        }
        onSave(slot)
    }

    func rename(_ e: Scoop.Entry) {
        renameText = e.name ?? ""
        renaming = e
    }

    func commitRename() {
        guard let e = renaming else { return }
        ScoopShelf.setName(renameText, dish, e.slot)
        renaming = nil
        reload()
    }

    func delete(_ e: Scoop.Entry) {
        Scoop.remove(dish, e.slot)
        NSLog("[Scoop] 칸 지움 \(e.slot.tag)")
        reload()
    }

    static let menuItems = ["덮어쓰기", "이름 바꾸기", "지우기"]

    func runMenu(_ e: Scoop.Entry, _ i: Int) {
        menuFor = nil
        switch i {
        case 0: confirmOverwrite = e
        case 1: rename(e)
        default: confirmDelete = e
        }
    }

    /// 컨트롤러 버튼
    func handle(_ b: PadButton) {
        controllerFocus = true
        // 열린 확인 창: A 확인, B 취소
        if let e = confirmLoad {
            if b == .a { confirmLoad = nil; onLoad(e.slot) } else if b == .b || b == .menu { confirmLoad = nil }
            return
        }
        if let e = confirmDelete {
            if b == .a { confirmDelete = nil; delete(e) } else if b == .b || b == .menu { confirmDelete = nil }
            return
        }
        if let e = confirmOverwrite {
            if b == .a { confirmOverwrite = nil; onSave(e.slot) } else if b == .b || b == .menu { confirmOverwrite = nil }
            return
        }
        if full { if b == .a || b == .b { full = false }; return }
        if renaming != nil { if b == .b { renaming = nil }; return }
        if let m = menuFor, let e = entries.first(where: { $0.slot == m }) {
            switch b {
            case .left: menuChoice = max(0, menuChoice - 1)
            case .right: menuChoice = min(Self.menuItems.count - 1, menuChoice + 1)
            case .a: runMenu(e, menuChoice)
            case .b, .y, .menu: menuFor = nil
            case .up, .down: menuFor = nil; move(b == .down ? 1 : -1)
            default: break
            }
            return
        }
        switch b {
        case .up: move(-1)
        case .down: move(1)
        case .a:
            if let f = focus, let e = entries.first(where: { $0.slot == f }) { confirmLoad = e } else { move(1) }
        case .y:
            if let f = focus { menuFor = f; menuChoice = 0 }
        case .b, .menu, .home: onClose()
        default: break
        }
    }

    private func move(_ d: Int) {
        let order = entries.map(\.slot)
        guard !order.isEmpty else { return }
        guard let f = focus, let i = order.firstIndex(of: f) else { focus = order[0]; Rumble.shared.tap(intensity: 0.15); return }
        let n = min(order.count - 1, max(0, i + d))
        if n != i { focus = order[n]; Rumble.shared.tap(intensity: 0.15) }
    }
}

struct ScoopListView: View {
    @ObservedObject var model: ScoopList
    @AppStorage(Scoop.autoKey) private var autoOn = true

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if model.entries.isEmpty {
                        Text("아직 저장한 게 없어요. 일시정지 화면의 저장을 눌러 주세요").foregroundStyle(.secondary)
                    } else {
                        Section {
                            ForEach(model.entries) { e in
                                row(e)
                                    .id(e.slot)
                                    .listRowBackground(rowBackground(model.controllerFocus && model.focus == e.slot))
                            }
                        } header: {
                            Text("저장 \(model.entries.count)개")
                        } footer: {
                            Text("새 칸은 \(Scoop.maxStates)칸까지 저장돼요(지금 \(model.stateCount)칸). 게임 안 저장 칸과 따로 저장되고, 사진과 이름은 이 기기에만 남아요.")
                        }
                    }
                    Section {
                        Toggle("자동 저장", isOn: $autoOn).tint(Palette.accent)
                    } footer: {
                        Text("게임을 나갈 때와 \(max(1, Int(Scoop.autoEvery / 60)))분마다 '자동 저장' 칸에 저장해요. 맵에서 자유롭게 움직일 수 있을 때만 돼요.")
                    }
                }
                .onChange(of: model.focus) { _, f in
                    withAnimation(.easeOut(duration: 0.15)) {
                        if let f { proxy.scrollTo(f, anchor: .center) }
                    }
                }
            }
            .navigationTitle("불러오기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !model.entries.isEmpty {
                        Button(model.editing ? "완료" : "편집") { withAnimation(.easeOut(duration: 0.15)) { model.editing.toggle() } }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { model.onClose() } }
            }
        }
        .onAppear { model.editing = false; model.reload() }
        .alert("이 상태로 돌아갈까요?", isPresented: present(\.confirmLoad), presenting: model.confirmLoad) { e in
            Button("불러오기") { model.onLoad(e.slot) }
            Button("취소", role: .cancel) {}
        } message: { e in
            Text("\(Scoop.clock(e.date))에 저장한 상태로 돌아가요. 지금까지 한 진행 중 저장하지 않은 것은 사라져요. 게임 안 저장 칸은 그대로예요.")
        }
        .alert("이 칸에 덮어쓸까요?", isPresented: present(\.confirmOverwrite), presenting: model.confirmOverwrite) { e in
            Button("덮어쓰기") { model.onSave(e.slot) }
            Button("취소", role: .cancel) {}
        } message: { e in
            Text("\(Scoop.clock(e.date))에 저장한 상태가 지금 상태로 바뀌어요.")
        }
        .alert("이 칸을 지울까요?", isPresented: present(\.confirmDelete), presenting: model.confirmDelete) { e in
            Button("지우기", role: .destructive) { model.delete(e) }
            Button("취소", role: .cancel) {}
        } message: { e in
            Text("\(Scoop.clock(e.date))에 저장한 상태를 지워요. 다른 기기에서도 지워져요.")
        }
        .alert("이름 바꾸기", isPresented: present(\.renaming)) {
            TextField("이름", text: $model.renameText)
            Button("저장") { model.commitRename() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("비워 두면 이름 없이 시각만 보여요.")
        }
        .alert("칸이 가득 찼어요", isPresented: $model.full) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("상태는 \(Scoop.maxStates)칸까지 저장돼요. 지우거나 덮어써 주세요.")
        }
    }

    private func present<T>(_ kp: ReferenceWritableKeyPath<ScoopList, T?>) -> Binding<Bool> {
        Binding(get: { model[keyPath: kp] != nil }, set: { if !$0 { model[keyPath: kp] = nil } })
    }

    private func rowBackground(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(on ? Palette.accent.opacity(0.18) : Color(uiColor: .secondarySystemGroupedBackground))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.accent, lineWidth: on ? 2 : 0))
    }

    @ViewBuilder
    private func row(_ e: Scoop.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { if !model.editing { model.confirmLoad = e } } label: {
                SaveCardView(dish: model.dish, fileName: Scoop.fileName(model.dish, e.slot) ?? "", date: e.date, name: e.name)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.editing || model.menuFor == e.slot {
                HStack(spacing: 8) {
                    ForEach(ScoopList.menuItems.indices, id: \.self) { i in
                        Button(ScoopList.menuItems[i]) { model.runMenu(e, i) }
                            .buttonStyle(.bordered).tint(i == 2 ? .red : Palette.accent)
                            .overlay(Capsule().strokeBorder(Palette.accent, lineWidth: model.menuFor == e.slot && model.menuChoice == i ? 2.5 : 0).padding(-3))
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let f = Scoop.fileName(model.dish, e.slot) {
                Section("자세히") {
                    Text(f)
                    Text(ByteCountFormatter.string(fromByteCount: Scoop.url(model.dish, e.slot).flatMap {
                        (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }.map(Int64.init) ?? 0, countStyle: .file))
                }
            }
            Button { model.confirmOverwrite = e } label: { Label("덮어쓰기", systemImage: "square.and.arrow.down") }
            Button { model.rename(e) } label: { Label("이름 바꾸기", systemImage: "pencil") }
            Button(role: .destructive) { model.confirmDelete = e } label: { Label("지우기", systemImage: "trash") }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { model.confirmDelete = e } label: { Label("지우기", systemImage: "trash") }
            Button { model.rename(e) } label: { Label("이름", systemImage: "pencil") }.tint(.gray)
            Button { model.confirmOverwrite = e } label: { Label("덮어쓰기", systemImage: "square.and.arrow.down") }.tint(Palette.accent)
        }
    }
}
