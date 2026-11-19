import SwiftUI
import WebKit

/// 냉동실 선반: 기기에 남아 있는 게임별 저장 데이터(Documents/Saves/<폴더>) 목록과 지우기.
/// 게임을 지워도 저장 데이터는 남기 때문에, 설정 › 저장 데이터 관리와 삭제 알림의 "저장 데이터까지 삭제"가 여기를 쓴다.
enum FreezerShelf {
    struct Entry: Identifiable, Equatable {
        let folder: String
        let bytes: Int64
        let modified: Date?
        var id: String { folder }
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Saves", isDirectory: true)
    }

    static func entries() -> [Entry] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { IglooEngine.safeFolder($0) }.compactMap { name -> Entry? in
            let dir = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            var bytes: Int64 = 0
            var latest: Date?
            for case let u as URL in fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) ?? .init() {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                bytes += Int64(v?.fileSize ?? 0)
                if let d = v?.contentModificationDate, d > (latest ?? .distantPast) { latest = d }
            }
            // 빈 폴더(한 번도 저장 안 한 게임)는 보여 줄 게 없다
            return bytes > 0 ? Entry(folder: name, bytes: bytes, modified: latest) : nil
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// 그 폴더의 저장 데이터를 모두 지운다: 이 기기의 Saves/<폴더>, 같은 폴더를 쓰는 게임의 웹 저장소, 클라우드(지금 고른 선반) 사본.
    /// 실행 중인 게임은 부르는 쪽이 먼저 닫는다.
    @MainActor
    static func wipe(folder: String, dishes: [Dish]) async {
        guard IglooEngine.safeFolder(folder) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(folder, isDirectory: true))
        // 웹/Electron 게임은 localStorage 가 게임별 웹 저장소에도 있어, 이것까지 지워야 다시 열었을 때 처음부터 시작한다
        for d in dishes where !d.isRemote && d.dataPathApp == folder {
            await GlassBowl.removeStore(for: d)
        }
        await Igloo.shared.forget(folder: folder)
    }
}

/// 설정 › 저장 데이터 관리. 게임별 저장 데이터 크기·마지막 저장 시각·클라우드 상태를 보고, 누르면 그 게임의 세이브 파일 화면으로 간다.
/// PC 세이브 넣기(맞는 게임·슬롯 제안)와 지우기도 여기서
struct SavedDataView: View {
    let dishes: [Dish]
    /// 지우기 전에 그 게임이 켜져 있으면 닫는다 (설정은 게임 중에도 열 수 있다)
    var onWillWipe: (String) -> Void = { _ in }

    @ObservedObject private var igloo = Igloo.shared
    @State private var entries: [FreezerShelf.Entry] = []
    @State private var wiping: FreezerShelf.Entry?
    @State private var busy = false
    @State private var showPicker = false
    @State private var inserting: PickedSave?
    @State private var notice: FreezerModel.Notice?

    private func dish(_ e: FreezerShelf.Entry) -> Dish? {
        dishes.first { $0.dataPathApp == e.folder && !$0.isRemote } ?? dishes.first { $0.dataPathApp == e.folder }
    }
    private func title(_ e: FreezerShelf.Entry) -> String { dish(e)?.title ?? e.folder }

    var body: some View {
        List {
            Section {
                Button { pick() } label: { Label("PC 세이브 넣기", systemImage: "square.and.arrow.down") }
            } footer: {
                Text("PC의 세이브 파일(Game.rxdata·file1.rpgsave 등)이나 백업 파일을 고르면 맞는 게임을 찾아 넣어요.")
            }

            Section {
                if entries.isEmpty {
                    Text("저장 데이터가 없어요").foregroundStyle(.secondary)
                }
                ForEach(entries) { e in
                    HStack {
                        if let d = dish(e), !d.isRemote {
                            NavigationLink { SaveFilesView(dish: d) } label: { row(e) }
                        } else {
                            row(e)
                        }
                        Button(role: .destructive) { wiping = e } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(title(e)) 저장 데이터 삭제")
                    }
                    .swipeActions { Button("삭제", role: .destructive) { wiping = e } }
                }
            } header: {
                Text("게임별 저장 데이터")
            }
        }
        .navigationTitle("저장 데이터 관리")
        .disabled(busy)
        .onAppear { entries = FreezerShelf.entries() }
        .alert("‘\(wiping.map(title) ?? "")’ 저장 데이터를 삭제하시겠습니까?",
               isPresented: Binding(get: { wiping != nil }, set: { if !$0 { wiping = nil } }), presenting: wiping) { e in
            Button("삭제", role: .destructive) {
                busy = true
                onWillWipe(e.folder)
                Task {
                    await FreezerShelf.wipe(folder: e.folder, dishes: dishes)
                    entries = FreezerShelf.entries()
                    busy = false
                }
            }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("\(Igloo.shared.placesText)에서 진행 상황과 백업이 모두 지워지고 되돌릴 수 없어요.")
        }
        .alert(item: $notice) { n in Alert(title: Text(n.title), message: Text(n.message)) }
        .sheet(item: $inserting) { p in
            SaveInsertSheet(picked: p, suggestions: p.suggestions) { n in
                inserting = nil
                entries = FreezerShelf.entries()
                if let n { notice = n }
            }
        }
        // 창에서 직접 띄우는 선택기 (iPad 에서 시트 안 fileImporter 가 멈추는 문제, GamePicker). 고른 파일은 임시 복사본
        .background(GamePicker(isPresented: $showPicker, types: [.data]) { url in
            guard let url else { return }
            picked(url)
        }.frame(width: 0, height: 0))
    }

    private func row(_ e: FreezerShelf.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title(e))
            Text(detail(e)).font(.footnote).foregroundStyle(.secondary)
            if let c = cloud(e) { Text(c).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func detail(_ e: FreezerShelf.Entry) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file)]
        // 마지막 저장: 저장 데이터의 저장 시각, 없으면 폴더 안 파일의 가장 늦은 수정 시각
        let saved = dish(e).flatMap { $0.isRemote ? nil : Freezer(dish: $0).lastSaved } ?? e.modified
        if let d = saved { parts.append("마지막 저장 " + d.formatted(date: .abbreviated, time: .shortened)) }
        if dish(e) == nil { parts.append("게임 없음") }
        return parts.joined(separator: " · ")
    }

    /// 클라우드 상태 한 줄. 동기화를 안 쓰면 보이지 않는다
    private func cloud(_ e: FreezerShelf.Entry) -> String? {
        guard igloo.enabled else { return nil }
        guard let d = dish(e), !d.isRemote else { return nil }
        if let at = igloo.lastSynced(d) { return "\(igloo.backend.label) · \(Igloo.relative(at)) 동기화" }
        return "\(igloo.backend.label) · 아직 동기화 안 했어요"
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
        do {
            let got = try IceCubes.readPicked(url)
            let found = IceCubes.suggest(name: got.name, data: got.data, dishes: dishes)
            guard !found.isEmpty else { throw IceCubes.Rejection.unknown }
            inserting = PickedSave(name: got.name, data: got.data, target: nil, suggestions: found)
        } catch {
            notice = .init(title: "넣지 못했어요", message: (error as? LocalizedError)?.errorDescription ?? "파일을 읽을 수 없어요.")
        }
    }
}
