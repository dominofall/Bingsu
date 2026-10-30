import SwiftUI
import UniformTypeIdentifiers

/// 이 게임 설정 › 저장 데이터: 마지막 저장 시각, 백업 목록(되돌리기·삭제), PC 백업 가져오기·내보내기.
/// 로컬 게임에만 보인다 — 원격 웹 게임은 로그인 토큰이 섞여 있어 파일로 꺼내지 않는다 (8.2).
/// 확인 창·파일 선택은 Form 행에 붙이면 행마다 퍼지므로 `freezerPresentations(_:)`로 Form 에 붙인다.
@MainActor
final class FreezerModel: ObservableObject {
    let freezer: Freezer
    @Published var backups: [Freezer.Backup] = []
    @Published var lastSaved: Date?
    @Published var pendingRestore: Freezer.Backup?
    @Published var showImporter = false
    @Published var exportDoc: BackupDocument?
    @Published var notice: Notice?

    static let applyNote = "게임이 켜져 있으면 게임을 종료하고 다시 열 때 적용돼요."

    struct Notice: Identifiable {
        let title: String
        let message: String
        var id: String { title + message }
    }

    init(dish: Dish) { freezer = Freezer(dish: dish) }

    func reload() {
        backups = freezer.backups()
        lastSaved = freezer.lastSaved
    }

    func delete(_ b: Freezer.Backup) { freezer.delete(b); reload() }

    func restore(_ b: Freezer.Backup) {
        do {
            try freezer.restore(b)
            notice = Notice(title: "되돌렸어요", message: Self.applyNote)
        } catch {
            notice = Notice(title: "되돌리지 못했어요", message: (error as? LocalizedError)?.errorDescription ?? "이 백업 파일을 읽을 수 없어요.")
        }
        reload()
    }

    func importBackup(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
        // 크기부터 본다: 상한보다 큰 파일은 읽지도 않는다
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Freezer.maxBytes else { return notice = Notice(title: "가져오지 못했어요", message: Freezer.ImportError.tooLarge.errorDescription!) }
        do {
            try freezer.replace(with: Data(contentsOf: url))
            notice = Notice(title: "가져왔어요", message: "지금 저장 데이터는 백업해 뒀어요. \(Self.applyNote)")
        } catch let e as Freezer.ImportError {
            notice = Notice(title: "가져오지 못했어요", message: e.errorDescription!)
        } catch {
            notice = Notice(title: "가져오지 못했어요", message: "파일을 읽을 수 없어요.")
        }
        reload()
    }

    /// PC판과 같은 모양 {format, version, data} 으로만 내보낸다 (빙수 메타 savedAt 은 뺀다)
    func prepareExport() {
        guard let snap = freezer.loadLocalStorage(),
              let data = try? JSONSerialization.data(withJSONObject: ["format": Freezer.format, "version": 1, "data": snap.entries] as [String: Any],
                                                     options: [.sortedKeys]) else {
            return notice = Notice(title: "내보내지 못했어요", message: "아직 저장된 데이터가 없어요.")
        }
        exportDoc = BackupDocument(data: data)
    }
}

struct FreezerSection: View {
    @ObservedObject var model: FreezerModel
    @ObservedObject private var igloo = Igloo.shared
    @AppStorage(Igloo.enabledKey) private var icloudSync = true

    var body: some View {
        Section {
            LabeledContent("마지막 저장") {
                Text(model.lastSaved.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "아직 없음")
            }
            LabeledContent("iCloud 동기화") {
                if !icloudSync { Text("꺼져 있어요") }
                else if let d = igloo.lastSynced(model.freezer.dish) { Text(Igloo.relative(d)) }
                else { Text("아직 안 했어요") }
            }
            Button { model.prepareExport() } label: { Label("백업 파일 내보내기", systemImage: "square.and.arrow.up") }
                .disabled(model.lastSaved == nil)
            Button { model.showImporter = true } label: { Label("PC 백업 가져오기", systemImage: "square.and.arrow.down") }
        } header: {
            Text("저장 데이터")
        } footer: {
            Text("PC에서 \"백업 파일 내보내기\"로 만든 파일을 가져올 수 있어요. 가져오거나 되돌리기 전에 지금 저장 데이터는 자동으로 백업해 둬요.")
        }

        Section {
            if model.backups.isEmpty {
                Text("백업이 없어요").foregroundStyle(.secondary)
            }
            ForEach(model.backups) { b in
                Button { model.pendingRestore = b } label: {
                    HStack {
                        Label(b.date.formatted(date: .abbreviated, time: .shortened), systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    Button(role: .destructive) { model.delete(b) } label: { Label("삭제", systemImage: "trash") }
                        .tint(.red)   // Form 의 포인트 색이 삭제 버튼까지 칠하지 않게
                }
            }
        } header: {
            Text("백업")
        }
    }
}

extension View {
    func freezerPresentations(_ model: FreezerModel) -> some View {
        self
            .onAppear { model.reload() }
            .confirmationDialog("이 백업으로 되돌릴까요?",
                                isPresented: Binding(get: { model.pendingRestore != nil }, set: { if !$0 { model.pendingRestore = nil } }),
                                titleVisibility: .visible, presenting: model.pendingRestore) { b in
                Button("이 백업으로 되돌리기", role: .destructive) { model.restore(b) }
                Button("취소", role: .cancel) {}
            } message: { b in
                Text("\(b.date.formatted(date: .abbreviated, time: .shortened)) 저장 데이터로 바꿔요. 지금 저장 데이터는 먼저 백업해 둬요. \(FreezerModel.applyNote)")
            }
            .fileImporter(isPresented: Binding(get: { model.showImporter }, set: { model.showImporter = $0 }), allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                model.importBackup(url)
            }
            .fileExporter(isPresented: Binding(get: { model.exportDoc != nil }, set: { if !$0 { model.exportDoc = nil } }),
                          document: model.exportDoc, contentType: .json,
                          defaultFilename: (model.freezer.exportFileName as NSString).deletingPathExtension) { result in
                if case .failure = result { model.notice = FreezerModel.Notice(title: "내보내지 못했어요", message: "다시 시도해 주세요.") }
            }
            .alert(item: Binding(get: { model.notice }, set: { model.notice = $0 })) { n in
                Alert(title: Text(n.title), message: Text(n.message))
            }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = d
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
