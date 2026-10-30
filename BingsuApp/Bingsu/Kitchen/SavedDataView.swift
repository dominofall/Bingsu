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

    /// 그 폴더의 저장 데이터를 모두 지운다: 이 기기의 Saves/<폴더>, 같은 폴더를 쓰는 게임의 웹 저장소, iCloud 사본.
    /// 실행 중인 게임은 부르는 쪽이 먼저 닫는다.
    @MainActor
    static func wipe(folder: String, dishes: [Dish]) async {
        guard IglooEngine.safeFolder(folder) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(folder, isDirectory: true))
        // 웹/Electron 게임은 localStorage 가 게임별 웹 저장소에도 있어, 이것까지 지워야 다시 열었을 때 처음부터 시작한다
        for d in dishes where !d.isRemote && d.dataPathApp == folder {
            try? await WKWebsiteDataStore.remove(forIdentifier: GlassBowl.storeID(for: d))
        }
        await Igloo.shared.forget(folder: folder)
    }
}

/// 설정 › 저장 데이터 관리. 게임별 저장 데이터 크기·마지막 저장 시각을 보고 지운다
struct SavedDataView: View {
    let dishes: [Dish]
    /// 지우기 전에 그 게임이 켜져 있으면 닫는다 (설정은 게임 중에도 열 수 있다)
    var onWillWipe: (String) -> Void = { _ in }

    @State private var entries: [FreezerShelf.Entry] = []
    @State private var wiping: FreezerShelf.Entry?
    @State private var busy = false

    private func title(_ e: FreezerShelf.Entry) -> String {
        dishes.first { $0.dataPathApp == e.folder }?.title ?? e.folder
    }
    private func isInstalled(_ e: FreezerShelf.Entry) -> Bool { dishes.contains { $0.dataPathApp == e.folder } }

    var body: some View {
        List {
            if entries.isEmpty {
                Text("저장 데이터가 없어요").foregroundStyle(.secondary)
            }
            ForEach(entries) { e in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(e))
                        Text(detail(e)).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { wiping = e } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("\(title(e)) 저장 데이터 삭제")
                }
                .swipeActions { Button("삭제", role: .destructive) { wiping = e } }
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
            Text("이 기기와 iCloud 에서 진행 상황과 백업이 모두 지워지고 되돌릴 수 없어요.")
        }
    }

    private func detail(_ e: FreezerShelf.Entry) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file)]
        if let d = e.modified { parts.append(d.formatted(date: .abbreviated, time: .shortened)) }
        if !isInstalled(e) { parts.append("게임 없음") }
        return parts.joined(separator: " · ")
    }
}
