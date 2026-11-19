import SwiftUI
import UniformTypeIdentifiers

/// 이 게임 설정 › 저장 데이터: 세이브 파일·마지막 저장·클라우드 동기화·백업으로 가는 줄. 넣기·내보내기는 세이브 파일 화면에서.
/// 로컬 게임에만 보인다 — 원격 웹 게임은 로그인 토큰이 섞여 있어 파일로 꺼내지 않는다 (8.2).
/// 확인 창·파일 선택은 Form 행에 붙이면 행마다 퍼지므로 `freezerPresentations(_:)`로 Form 에 붙인다.
@MainActor
final class FreezerModel: ObservableObject {
    let freezer: Freezer
    @Published var backups: [Freezer.Backup] = []
    @Published var lastSaved: Date?
    /// 세이브 파일 수 (IceCubes.list)
    @Published var fileCount = 0
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
        fileCount = IceCubes.list(freezer.dish).count
    }

    func delete(_ b: Freezer.Backup) { freezer.delete(b); reload() }

    /// 지금 저장 데이터를 날짜 붙여 백업 (빌드 50: 일시정지 화면에서 이리로 옮김). 게임이 켜져 있어도 파일은 건드리지 않고 묶기만 한다
    func backupNow() {
        IceTray.sync(freezer.dish, allowUnpack: false)
        if freezer.freeze() == nil {
            notice = Notice(title: "백업할 데이터가 없어요", message: "아직 게임 안에서 저장한 데이터가 없어요.")
        }
        reload()
    }

    /// save.json 을 바꾼 뒤: 게임이 꺼져 있으면 파일로 저장하는 게임은 바로 파일로 풀고(세이브 파일 목록에 바로 보이게), 클라우드에 올린다
    private func settle() {
        let dish = freezer.dish
        guard !SaveDoor.shared.isRunning(dish) else { return }
        IceTray.sync(dish, allowUnpack: true)
        Igloo.shared.afterPlay(dish, stillRunning: false)
    }

    func restore(_ b: Freezer.Backup) {
        do {
            try freezer.restore(b)
            settle()
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
            settle()
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

    var body: some View {
        Section {
            NavigationLink {
                SaveFilesView(dish: model.freezer.dish)
            } label: {
                LabeledContent("세이브 파일", value: model.fileCount == 0 ? "없음" : "\(model.fileCount)개")
            }
            LabeledContent("마지막 저장") {
                Text(model.lastSaved.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "아직 없음")
            }
            LabeledContent("클라우드 동기화") {
                if !igloo.enabled { Text("꺼져 있어요") }
                else if let d = igloo.lastSynced(model.freezer.dish) { Text("\(igloo.backend.label) · \(Igloo.relative(d))") }
                else { Text("\(igloo.backend.label) · 아직 안 했어요") }
            }
            NavigationLink {
                BackupListView(dish: model.freezer.dish)
            } label: {
                LabeledContent("백업", value: model.backups.isEmpty ? "없음" : "\(model.backups.count)개")
            }
        } header: {
            Text("저장 데이터")
        } footer: {
            Text("세이브 파일에서 PC·다른 앱의 세이브를 넣거나 내보내요. 바꾸거나 되돌리기 전에 지금 저장 데이터는 자동으로 백업해 둬요.")
        }
    }
}

/// 이 게임 설정 › 저장 데이터 › 백업: 백업 목록만 따로 (되돌리기·삭제 확인은 이 화면의 모델로)
struct BackupListView: View {
    @StateObject private var model: FreezerModel

    init(dish: Dish) { _model = StateObject(wrappedValue: FreezerModel(dish: dish)) }

    var body: some View {
        List {
            Section {
                Button { model.backupNow() } label: { Label("지금 백업", systemImage: "plus.circle.fill") }
            } footer: {
                Text("지금 이 게임의 세이브 전체를 날짜별로 남겨요. 세이브를 바꾸거나 되돌리기 전에는 저절로 백업돼요.")
            }
            FreezerBackupSection(model: model, showsHeader: false)
        }
            .navigationTitle("백업")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Palette.accent)
            .freezerPresentations(model)
    }
}

/// 백업 목록(되돌리기·삭제). 백업 화면과 세이브 파일 화면이 같이 쓴다
struct FreezerBackupSection: View {
    @ObservedObject var model: FreezerModel
    /// 칸 제목 "백업" (백업 화면에서는 화면 제목과 겹쳐 뺀다)
    var showsHeader = true

    var body: some View {
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
            if showsHeader { Text("백업") }
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
