import SwiftUI
import PhotosUI

/// 게임 하나의 설정: 표지 이미지, 이 게임만의 가상 패드 설정, 컨트롤러 진동표, 성능(화질·기록), 저장 데이터(로컬 게임만).
/// 게임 목록에서 게임칩을 꾹 눌러 열거나, 게임 중 일시정지 시트 "이 게임 설정"으로 연다.
struct DishSettingsView: View {
    let dish: Dish
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DishPrefsStore.shared
    @State private var photoItem: PhotosPickerItem?
    @State private var showRumblePicker = false
    @State private var rumbleCard: RumbleCard?
    @State private var rumbleIsOwn = false
    @State private var rumbleNote: String?
    @State private var rumbleExportURL: URL?
    @StateObject private var freezerModel: FreezerModel

    init(dish: Dish) {
        self.dish = dish
        _freezerModel = StateObject(wrappedValue: FreezerModel(dish: dish))
    }

    private var prefs: DishPrefs { store.prefs(for: dish.id) }
    private var usesOwnPad: Binding<Bool> {
        Binding(get: { prefs.pad != nil },
                set: { on in store.update(dish.id) { $0.pad = on ? ($0.pad ?? PadPrefs.global()) : nil } })
    }
    private var ownPad: Binding<PadPrefs> {
        Binding(get: { prefs.pad ?? PadPrefs.global() },
                set: { p in store.update(dish.id) { $0.pad = p } })
    }

    private enum SilentChoice: Hashable { case global, on, off }
    @AppStorage(BingsuApp.playInSilentKey) private var globalPlayInSilent = true
    private var silentChoice: Binding<SilentChoice> {
        Binding(get: { prefs.playInSilent.map { $0 ? .on : .off } ?? .global },
                set: { c in
                    store.update(dish.id) { $0.playInSilent = c == .global ? nil : c == .on }
                    BingsuApp.configureAudioSession()
                    NotificationCenter.default.post(name: BingsuApp.soundPrefsChanged, object: nil)
                })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("표지") {
                    HStack(spacing: 16) {
                        GameChipCover(dish: dish, coverURL: store.coverURL(for: dish.id))
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(dish.title).font(.headline)
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Label("사진에서 고르기", systemImage: "photo")
                            }
                            if prefs.coverFile != nil {
                                Button(role: .destructive) { store.setCover(nil, for: dish.id) } label: {
                                    Label("기본 표지로", systemImage: "arrow.uturn.backward")
                                }
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Toggle(isOn: usesOwnPad) {
                        Text("이 게임만의 패드 설정")
                        Text(usesOwnPad.wrappedValue ? "아래 설정은 이 게임에만 적용돼요" : "끄면 설정 > 가상 패드의 값을 따라요")
                    }
                    if usesOwnPad.wrappedValue {
                        PadPrefsControls(prefs: ownPad)
                        Button("기본 설정 값으로 되돌리기") { ownPad.wrappedValue = PadPrefs.global() }
                    }
                } header: {
                    Text("가상 패드")
                }

                Section {
                    Picker("무음 모드에서도 소리 재생", selection: silentChoice) {
                        Text("기본 설정 따르기 (\(globalPlayInSilent ? "켬" : "끔"))").tag(SilentChoice.global)
                        Text("켬").tag(SilentChoice.on)
                        Text("끔").tag(SilentChoice.off)
                    }
                } header: {
                    Text("소리")
                } footer: {
                    Text("끄면 무음 모드일 때 이 게임 소리가 나지 않고, 다른 앱의 음악과 함께 들려요. 소리 크기는 설정 › 게임 중에서 모든 게임에 같이 정해요.")
                }

                if dish.recipe == .mkxp {
                    Section {
                        Toggle("온라인 접속 허용", isOn: Binding(get: { prefs.allowOnline != false },
                                                             set: { on in store.update(dish.id) { $0.allowOnline = on ? nil : false } }))
                    } header: {
                        Text("온라인")
                    } footer: {
                        Text("켜 두면 게임이 인터넷 서버에 접속해 온라인 멀티를 할 수 있어요. 믿을 수 있는 서버에만 접속하세요. 끄면 인터넷이 없는 것처럼 실행돼요. 바꾼 값은 게임을 처음 켤 때 적용돼요. 이미 한 번 켰다면 빙수를 완전히 닫았다 다시 열어 주세요.")
                    }
                }

                Section {
                    LabeledContent("지금 쓰는 표", value: rumbleSummary)
                    Button { showRumblePicker = true } label: { Label("JSON 가져오기", systemImage: "square.and.arrow.down") }
                    if let url = rumbleExportURL {
                        ShareLink(item: url) {
                            Label(rumbleCard == nil ? "빈 양식 내보내기" : "지금 표 내보내기", systemImage: "square.and.arrow.up")
                        }
                    }
                    if rumbleIsOwn {
                        Button(role: .destructive) {
                            RumbleShelf.removeUserFile(for: dish.id)
                            refreshRumble()
                            rumbleNote = "직접 넣은 표를 지웠어요"
                        } label: { Label("기본 진동표로", systemImage: "arrow.uturn.backward") }
                    }
                    if let rumbleNote { Text(rumbleNote).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("컨트롤러 진동")
                } footer: {
                    Text("게임에서 효과음이 날 때 이 표에 맞춰 컨트롤러를 울려요. 형식은 빙수 안내 문서의 진동표 항목(docs/rumble)을 따라요.")
                }

                PerfSection(dish: dish)

                if !dish.isRemote { FreezerSection(model: freezerModel) }
            }
            .freezerPresentations(freezerModel)
            .tint(Palette.accent)
            .navigationTitle("이 게임 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    store.setCover(img, for: dish.id)
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showRumblePicker, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            importRumble(url)
        }
        .onAppear(perform: refreshRumble)
    }

    // MARK: 진동표

    private var rumbleSummary: String {
        guard let card = rumbleCard else { return "없음" }
        return (rumbleIsOwn ? "직접 넣은 표" : "기본 (\(card.game))") + " · 규칙 \(card.set.rules.count)개"
    }

    /// 내보낼 파일: 지금 표 파일, 표가 없으면 새로 쓸 수 있는 양식
    private func exportURL() -> URL? {
        if let url = rumbleCard?.url { return url }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rumble-template.json")
        let template = """
        {
          "format": 1,
          "game": "\(dish.title.replacingOccurrences(of: "\"", with: "").prefix(40))",
          "rules": [
            { "sound": "hit", "match": "contains", "strong": 0.8, "weak": 0.4, "duration": 0.15 }
          ]
        }
        """
        return (try? template.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    private func refreshRumble() {
        let own = RumbleShelf.userCard(for: dish.id)
        rumbleIsOwn = own != nil
        rumbleCard = own ?? RumbleShelf.bundledCard(for: dish)
        rumbleExportURL = exportURL()
    }

    private func importRumble(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
        // 크기부터 보고 읽는다 (큰 파일을 통째로 올리지 않게)
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > RumbleShelf.maxFileBytes {
            rumbleNote = "가져오지 못했어요: 파일이 64KB 를 넘어요"; return
        }
        guard let data = try? Data(contentsOf: url) else { rumbleNote = "가져오지 못했어요: 파일을 읽을 수 없어요"; return }
        do {
            let r = try RumbleShelf.importUserFile(data, for: dish.id)
            rumbleNote = "규칙 \(r.rules)개를 넣었어요" + (r.skipped > 0 ? " (틀린 규칙 \(r.skipped)개는 뺐어요)" : "")
        } catch {
            rumbleNote = "가져오지 못했어요: " + ((error as? RumbleShelf.Rejection)?.reason ?? "알 수 없는 오류")
        }
        refreshRumble()
    }
}
