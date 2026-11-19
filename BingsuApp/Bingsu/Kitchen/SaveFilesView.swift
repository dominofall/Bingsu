import SwiftUI
import UniformTypeIdentifiers

/// 게임 하나의 세이브 파일 화면: 세이브 파일 목록(이름·저장 시각·크기), 파일마다 PC로 내보내기·PC 세이브로 바꾸기·지우기,
/// PC 세이브 넣기, 모두 내보내기(여러 개면 zip), 백업 목록(되돌리기).
/// 이 게임 설정 › 저장 데이터 › 세이브 파일, 설정 › 저장 데이터 관리 › 게임, 게임 목록에서 길게 눌러
/// 세이브 가져오기·내보내기(`SaveFilesSheet`)에서 연다. 무료 기능(잠금 없음)
struct SaveFilesView: View {
    /// 화면이 뜨자마자 할 일 (길게 누르기 메뉴에서 열 때)
    enum Start { case pick, export }

    let dish: Dish
    var start: Start?
    @State private var started = false
    @StateObject private var model: FreezerModel
    @ObservedObject private var door = SaveDoor.shared
    @State private var cubes: [IceCube] = []
    @State private var deleting: IceCube?
    /// 고른 파일로 바꿀 자리 (nil 이면 "PC 세이브 넣기": 슬롯을 제안)
    @State private var replaceTarget: IceCube?
    @State private var showPicker = false
    @State private var pendingReplace: PickedSave?
    @State private var inserting: PickedSave?

    init(dish: Dish, start: Start? = nil) {
        self.dish = dish
        self.start = start
        _model = StateObject(wrappedValue: FreezerModel(dish: dish))
    }

    private var running: Bool { door.isRunning(dish) }

    var body: some View {
        List {
            if running {
                Section {
                    Label("게임이 켜져 있어 세이브 파일을 바꾸거나 지울 수 없어요. 게임을 끝낸 뒤에 해 주세요.", systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if cubes.isEmpty {
                Section {
                    Text("아직 세이브 파일이 없어요").foregroundStyle(.secondary)
                } header: {
                    Text("게임 세이브")
                } footer: {
                    Text(IceCubes.pcHint(dish))
                }
            }
            // 세 칸: 게임 세이브(게임 안 저장 슬롯) · 빙수 저장(자동·빠른·상태 저장) · 게임 설정 파일(세이브 아님)
            ForEach(IceCubes.Shelf.allCases, id: \.self) { shelf in
                let items = IceCubes.sorted(cubes.filter { IceCubes.shelf($0, dish: dish) == shelf })
                if !items.isEmpty {
                    Section {
                        ForEach(items) { c in row(c) }
                    } header: {
                        Text(Self.title(shelf))
                    } footer: {
                        switch shelf {
                        case .game: Text(IceCubes.pcHint(dish))
                        case .bingsu: Text("빙수가 만든 저장이에요. 게임 안 저장 목록에는 보이지 않아요.")
                        case .other: Text("세이브가 아니라 게임이 쓰는 파일(저장 목록 정보·옵션 등)이에요. 보통은 건드리지 않아도 돼요. 바꾸거나 지우면 게임의 저장 목록이나 옵션이 어긋날 수 있어요.")
                        }
                    }
                }
            }

            Section {
                Button { replaceTarget = nil; pick() } label: { Label("PC 세이브 넣기", systemImage: "square.and.arrow.down") }
                    .disabled(running)
                if cubes.count > 1 {
                    Button { export(IceCubes.exportAll(cubes, dish: dish)) } label: {
                        Label("모두 PC로 내보내기 (zip)", systemImage: "square.and.arrow.up.on.square")
                    }
                }
            } footer: {
                Text("바꾸거나 지우기 전에 지금 저장 데이터를 자동으로 백업해 둬요. 아래 백업에서 되돌릴 수 있어요.")
            }

            FreezerBackupSection(model: model)

            // 맨 아래: PC·다른 앱·다른 기기에서 세이브를 가져오는 방법
            Section {
                NavigationLink { SaveImportGuideView(dish: dish) } label: {
                    Label("다른 기기에서 세이브 가져오는 법", systemImage: "questionmark.circle")
                }
            }
        }
        .navigationTitle("세이브 파일")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.accent)
        .onAppear {
            reload()
            guard let start, !started else { return }
            started = true
            // 시트가 다 뜬 뒤에 선택기를 띄운다 (뜨는 중에 띄우면 iPad 에서 무시될 때가 있다)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                switch start {
                case .pick: replaceTarget = nil; pick()
                case .export:
                    if cubes.isEmpty { model.notice = .init(title: "내보낼 세이브가 없어요", message: "게임에서 한 번 저장한 뒤에 내보낼 수 있어요.") }
                    else { export(IceCubes.exportAll(cubes, dish: dish)) }
                }
            }
        }
        .freezerPresentations(model)
        .onChange(of: model.backups) { _, _ in cubes = IceCubes.list(dish) }   // 백업 되돌리기 뒤
        .alert("‘\(deleting?.displayName ?? "")’을(를) 지울까요?",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { c in
            Button("지우기", role: .destructive) { remove(c) }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("지우기 전에 지금 저장 데이터를 백업해 둬요. 백업에서 되돌릴 수 있어요.")
        }
        .alert("‘\(pendingReplace?.target ?? "")’을(를) 바꿀까요?",
               isPresented: Binding(get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } }), presenting: pendingReplace) { p in
            Button("바꾸기", role: .destructive) { put(p.data, as: p.target ?? "") }
            Button("취소", role: .cancel) {}
        } message: { p in
            Text("고른 파일(\(p.name))로 바꿔요. 지금 저장 데이터는 먼저 백업해 둬요.")
        }
        .sheet(item: $inserting) { p in
            SaveInsertSheet(picked: p, suggestions: p.suggestions) { message in
                inserting = nil
                reload()
                if let message { model.notice = message }
            }
        }
        // 창에서 직접 띄우는 선택기 (iPad 에서 시트 안 fileImporter 가 멈추는 문제, GamePicker). 고른 파일은 임시 복사본
        .background(GamePicker(isPresented: $showPicker, types: [.data]) { url in
            guard let url else { return }
            picked(url)
        }.frame(width: 0, height: 0))
    }

    private static func title(_ shelf: IceCubes.Shelf) -> String {
        switch shelf {
        case .game: return "게임 세이브"
        case .bingsu: return "빙수 저장"
        case .other: return "게임 설정 파일"
        }
    }

    /// 파일 한 줄. 누르면 그 행에 붙은 메뉴 (iPad 에서도 행 옆에 뜬다)
    private func row(_ c: IceCube) -> some View {
        Menu {
            // 카드는 파일 이름·크기를 숨기므로 메뉴에서 보이게 (빌드 49)
            if !c.isSnapshot {
                Section("자세히") {
                    Text(c.fileName)
                    Text(ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file))
                }
            }
            Button { export(IceCubes.exportAll([c], dish: dish)) } label: { Label("PC로 내보내기", systemImage: "square.and.arrow.up") }
            if !running {
                Button { replaceTarget = c; pick() } label: { Label("PC 세이브로 바꾸기", systemImage: "arrow.left.arrow.right") }
                if !c.isSnapshot {
                    Button(role: .destructive) { deleting = c } label: { Label("지우기", systemImage: "trash") }
                }
            }
        } label: { SaveFileRow(cube: c, dish: dish, label: IceCubes.label(c, dish: dish)) }
            .foregroundStyle(.primary)
            .swipeActions {
                if !c.isSnapshot {
                    Button(role: .destructive) { deleting = c } label: { Label("지우기", systemImage: "trash") }
                        .tint(.red)
                        .disabled(running)
                }
            }
    }

    private func reload() {
        ScoopShelf.movePhotos(dish)
        SaveCard.ingest(dish)
        cubes = IceCubes.list(dish)
        model.reload()
    }

    private func export(_ url: URL?) {
        guard let url else { return model.notice = .init(title: "내보내지 못했어요", message: "파일을 준비하지 못했어요. 다시 시도해 주세요.") }
        SaveExporter.present(url)
    }

    private func remove(_ c: IceCube) {
        do {
            try IceCubes.remove(c, from: dish)
            model.notice = .init(title: "지웠어요", message: "지우기 전 저장 데이터는 백업에 있어요.")
        } catch {
            model.notice = .init(title: "지우지 못했어요", message: (error as? LocalizedError)?.errorDescription ?? "다시 시도해 주세요.")
        }
        reload()
    }

    private func put(_ data: Data, as name: String) {
        do {
            try IceCubes.put(data, as: name, into: dish)
            model.notice = .init(title: "바꿨어요", message: "지금 저장 데이터는 백업해 뒀어요. 다음에 게임을 열면 바꾼 세이브로 이어 해요.")
        } catch {
            model.notice = .init(title: "바꾸지 못했어요", message: (error as? LocalizedError)?.errorDescription ?? "다시 시도해 주세요.")
        }
        reload()
    }

    /// 파일 고르기. 디버그: BINGSU_SAVEPICK=<경로> 면 선택기 대신 그 파일의 임시 사본을 고른 것으로 (시뮬레이터 확인용)
    private func pick() {
        if let path = DevEnv["BINGSU_SAVEPICK"] {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let copy = tmp.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)) != nil { return picked(copy) }
        }
        showPicker = true
    }

    private func picked(_ url: URL) {
        defer { if Delivery.isOwnCopy(url) { try? FileManager.default.removeItem(at: url) } }
        let got: (name: String, data: Data)
        do { got = try IceCubes.readPicked(url) } catch {
            return model.notice = .init(title: "넣지 못했어요", message: (error as? LocalizedError)?.errorDescription ?? "파일을 읽을 수 없어요.")
        }
        // zip 은 풀어 주지 않는다: 통째로 넣으면 쓸모없는 파일이 슬롯에 들어간다
        if (got.name as NSString).pathExtension.lowercased() == "zip" {
            replaceTarget = nil
            return model.notice = .init(title: "zip 파일은 넣을 수 없어요", message: "파일 앱에서 zip을 눌러 먼저 푼 뒤, 안의 세이브 파일을 골라 주세요.")
        }
        if let target = replaceTarget {
            replaceTarget = nil
            // 자리를 정해 바꾸기: 같은 종류 파일이어야 한다
            if target.isSnapshot {
                guard (try? model.freezer.validate(got.data)) != nil else {
                    return model.notice = .init(title: "바꾸지 못했어요", message: Freezer.ImportError.notBackup.errorDescription!)
                }
            } else {
                let want = (target.name as NSString).pathExtension.lowercased()
                guard (got.name as NSString).pathExtension.lowercased() == want else {
                    return model.notice = .init(title: "바꾸지 못했어요", message: "확장자가 달라요. .\(want) 파일을 골라 주세요.")
                }
            }
            pendingReplace = PickedSave(name: got.name, data: got.data, target: target.name)
            return
        }
        let found = IceCubes.suggest(name: got.name, data: got.data, dishes: [dish], only: dish)
        guard !found.isEmpty else {
            return model.notice = .init(title: "넣지 못했어요", message: IceCubes.Failure.notForGame.errorDescription!)
        }
        inserting = PickedSave(name: got.name, data: got.data, target: nil, suggestions: found)
    }
}

/// 게임 목록 › 길게 누르기 › 세이브 가져오기·내보내기: 세이브 파일 화면을 시트로 열고 곧바로 선택기·저장 창을 띄운다
struct SaveFilesSheet: View {
    let dish: Dish
    let start: SaveFilesView.Start
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SaveFilesView(dish: dish, start: start)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
    }
}

/// 고른 PC 세이브 (이름·내용). `target` 은 바꿀 자리가 정해졌을 때
struct PickedSave: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    var target: String?
    /// 맞는 게임·슬롯 (PC 세이브 넣기). 시트가 따로 둔 상태 대신 이것을 보게 해 고른 순간의 값이 그대로 간다
    var suggestions: [IceCubes.Suggestion] = []
}

/// 세이브 칸이면 세이브 카드, 그 밖(저장 목록 정보·설정 파일·save.json)은 이름 줄
struct SaveFileRow: View {
    let cube: IceCube
    let dish: Dish
    /// "슬롯 1"·"자동 저장" 같은 이름. 있으면 크게, 파일 이름은 아랫줄에
    var label: String? = nil
    var body: some View {
        if !cube.isSnapshot, SaveCard.slotLabel(cube.name) != nil {
            HStack {
                SaveCardView(dish: dish, fileName: cube.name, date: cube.modified)
                Image(systemName: "ellipsis.circle").foregroundStyle(.tertiary)
            }
        } else {
            plain
        }
    }

    private var plain: some View {
        HStack {
            Image(systemName: cube.isSnapshot ? "doc.text" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label ?? cube.displayName).lineLimit(1).truncationMode(.middle)
                if label != nil {
                    Text(cube.fileName).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text([cube.modified?.formatted(date: .abbreviated, time: .shortened),
                      ByteCountFormatter.string(fromByteCount: cube.bytes, countStyle: .file)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "ellipsis.circle").foregroundStyle(.tertiary)
        }
    }
}

/// PC 세이브 넣기: 맞는 게임·슬롯을 먼저 고른 채로 보이고, 여럿이면 고르게 한다
struct SaveInsertSheet: View {
    let picked: PickedSave
    let suggestions: [IceCubes.Suggestion]
    /// 닫을 때. 알림(넣었어요·실패)이 있으면 넘긴다
    var onDone: (FreezerModel.Notice?) -> Void

    @State private var choice: IceCubes.Suggestion.ID?
    @State private var slot = ""
    @State private var error: String?

    private var chosen: IceCubes.Suggestion? { suggestions.first { $0.id == choice } ?? suggestions.first }
    private var slots: [String] { chosen.map(IceCubes.slots(for:)) ?? [] }
    private var replaces: Bool {
        guard let c = chosen else { return false }
        if !IceCubes.isFileGame(c.dish) { return c.replaces }
        return IceCubes.list(c.dish).contains { $0.name == slot }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("고른 파일", value: picked.name)
                    LabeledContent("크기", value: ByteCountFormatter.string(fromByteCount: Int64(picked.data.count), countStyle: .file))
                }
                Section {
                    if suggestions.count > 1 {
                        Picker("게임", selection: Binding(get: { choice ?? suggestions.first?.id }, set: { choice = $0; slot = chosen?.slot ?? "" })) {
                            ForEach(suggestions) { s in Text(s.dish.title).tag(Optional(s.id)) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } else if let c = chosen {
                        Text(c.dish.title)
                    }
                } header: {
                    Text(suggestions.count > 1 ? "어느 게임에 넣을까요?" : "게임")
                }
                if let c = chosen, IceCubes.isFileGame(c.dish) {
                    Section {
                        if slots.count > 1 {
                            Picker("넣을 자리", selection: $slot) {
                                ForEach(slots, id: \.self) { s in Text(display(s)).tag(s) }
                            }
                        } else {
                            LabeledContent("넣을 자리", value: display(slot))
                        }
                    } header: {
                        Text("슬롯")
                    }
                }
                Section {
                } footer: {
                    Text(replaces ? "같은 이름 세이브를 이 파일로 바꿔요. 지금 저장 데이터는 먼저 백업해 둬요."
                                  : "새 세이브 파일로 넣어요. 지금 저장 데이터는 먼저 백업해 둬요.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("PC 세이브 넣기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { onDone(nil) } }
                ToolbarItem(placement: .confirmationAction) { Button(replaces ? "바꾸기" : "넣기") { insert() }.disabled(chosen == nil) }
            }
            .onAppear { if slot.isEmpty { slot = suggestions.first?.slot ?? "" } }
        }
        .tint(Palette.accent)
    }

    private func display(_ s: String) -> String {
        let u = RedBeanSchemeHandler.userDataFolder + "/"
        return s.hasPrefix(u) ? String(s.dropFirst(u.count)) : s
    }

    private func insert() {
        guard let c = chosen else { return }
        do {
            try IceCubes.put(picked.data, as: IceCubes.isFileGame(c.dish) ? slot : c.slot, into: c.dish)
            onDone(.init(title: "넣었어요", message: "‘\(c.dish.title)’에 넣었어요. 지금 저장 데이터는 백업해 뒀어요. 다음에 게임을 열면 이 세이브로 이어 해요."))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "넣지 못했어요."
        }
    }
}

/// 내보내기: 파일 앱 "저장할 위치" 선택기를 창의 맨 위 화면에서 직접 띄운다 (iPad 에서 시트 안 fileExporter 가 멈추는 문제 회피)
@MainActor
enum SaveExporter {
    static func present(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let vc = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        vc.shouldShowFileExtensions = true
        vc.modalPresentationStyle = .formSheet
        top.present(vc, animated: true)
    }
}

/// 세이브 파일 › 다른 기기에서 세이브 가져오는 법: PC·다른 앱·다른 iPhone·iPad 별 순서와 알아 둘 것
struct SaveImportGuideView: View {
    let dish: Dish

    private var isFileGame: Bool { IceCubes.isFileGame(dish) }
    private var isMVMZ: Bool { dish.recipe == .rpgMakerMV }

    /// PC 에서 세이브가 있는 곳 (한 줄)
    private var pcWhere: String {
        if !isFileGame { return "PC 게임 안에서 \"백업 파일 내보내기\"로 .json 백업 파일을 만들어요." }
        if isMVMZ {
            return dish.mvmz?.engine == .mz
                ? "게임 폴더 안 save 폴더에 있어요 (file1.rmmzsave, global.rmmzsave 등)."
                : "게임 폴더 안 www\\save 폴더에 있어요 (file1.rpgsave, global.rpgsave 등)."
        }
        if dish.isRedBean { return "%APPDATA%\\\(dish.dataPathApp) 폴더에 있어요." }
        return "Essentials 게임은 %APPDATA%\\\(dish.dataPathApp) 폴더(Game.rxdata), 그 밖의 게임은 Game.exe 가 있는 게임 폴더(Save1.rxdata 등)에 있어요."
    }

    var body: some View {
        List {
            Section {
                step(1, pcWhere)
                step(2, "그 파일을 iPhone·iPad 로 옮겨요. iCloud Drive 에 올리거나, Mac 이면 AirDrop, 아니면 메일·메신저로 보낸 뒤 파일 앱에 저장해요.")
                step(3, "이 화면의 \"PC 세이브 넣기\"에서 그 파일을 고르고, 넣을 자리를 확인해요.")
            } header: {
                Text("PC 에서")
            } footer: {
                if isMVMZ {
                    Text("MV·MZ 게임은 global 파일도 같이 넣어야 게임의 불러오기 목록에 보여요. 이때 이 기기에만 있던 슬롯은 목록에서 안 보일 수 있어요(파일은 남아 있어요).")
                }
            }

            Section {
                step(1, "그 앱의 내보내기 기능이나 파일 앱 속 그 앱 폴더에서 세이브 파일을 꺼내 파일 앱에 저장해요. 이름(file1.rpgsave, Save1.rxdata 등)은 바꾸지 않아요.")
                step(2, "이 화면의 \"PC 세이브 넣기\"에서 골라요.")
            } header: {
                Text("다른 앱에서 (JoiPlay 등)")
            } footer: {
                Text("RPG Maker 원래 모양의 세이브 파일이면 넣을 수 있어요. 앱이 자기만의 모양으로 바꿔 저장했다면 넣어도 게임이 읽지 못할 수 있어요.")
            }

            Section {
                step(1, "설정 › 클라우드 동기화가 두 기기에서 켜져 있으면 저절로 옮겨져요.")
                step(2, "켜져 있지 않으면 그 기기에서 게임을 길게 눌러 \"세이브 내보내기\"로 파일을 만들고, AirDrop 등으로 이 기기에 보낸 뒤 여기서 넣어요.")
            } header: {
                Text("다른 iPhone·iPad 의 빙수에서")
            }

            Section {
                note("같은 게임, 같은 버전의 세이브여야 해요. 버전이나 패치가 다르면 깨질 수 있어요.")
                note("zip 파일은 파일 앱에서 눌러 먼저 풀고, 안의 세이브 파일을 하나씩 골라요.")
                note("넣거나 바꾸기 전에 지금 저장 데이터를 자동으로 백업해 둬요. 잘못 넣었으면 백업에서 되돌려요.")
                note("게임이 켜져 있으면 넣을 수 없어요. 게임을 끝낸 뒤에 넣어요.")
            } header: {
                Text("알아 둘 것")
            }
        }
        .navigationTitle("세이브 가져오는 법")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.accent)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(.subheadline.weight(.bold)).foregroundStyle(Palette.accent).frame(width: 18)
            Text(text).font(.subheadline)
        }
    }

    private func note(_ text: String) -> some View {
        Label { Text(text).font(.subheadline) } icon: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
    }
}
