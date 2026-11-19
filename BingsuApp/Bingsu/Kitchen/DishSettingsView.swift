import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import WebKit

/// 게임 하나의 설정. 순서: 표지 › 저장 데이터(로컬 게임만) › 조작(패드·컨트롤러·키보드·진동) › 소리·화면 › 인터넷.
/// 게임 목록에서 게임칩을 꾹 눌러 › 이 게임 설정으로 열거나, 게임 중 일시정지 › 이 게임 설정 더 보기로 연다.
/// 게임 중에 열었을 때만 맨 아래에 성능 기록과 진단 정보가 더 보인다 (화질·프레임 제한은 일시정지 화면에).
struct DishSettingsView: View {
    let dish: Dish
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DishPrefsStore.shared
    @State private var photoItem: PhotosPickerItem?
    @State private var showEditor = false
    /// 조작 › 컨트롤러 진동 줄에 보이는 요약 (진동 화면에서 돌아오면 다시 읽는다)
    @State private var rumbleSummary = ""
    @State private var showSoundFontPicker = false
    @State private var soundFont: SoundFontShelf.Font? = SoundFontShelf.current
    @State private var soundFontNote: String?
    @StateObject private var freezerModel: FreezerModel

    /// 게임 중에 열었을 때: 진단 정보를 지금 화면 상태와 함께 연다 (게임 컨테이너가 넘긴다).
    /// 목록에서 열면 nil — 그때는 성능·진단 칸을 보이지 않는다
    var onReceipt: (() -> Void)?

    init(dish: Dish, onReceipt: (() -> Void)? = nil) {
        self.dish = dish
        self.onReceipt = onReceipt
        _freezerModel = StateObject(wrappedValue: FreezerModel(dish: dish))
    }

    private var prefs: DishPrefs { store.prefs(for: dish.id) }
    /// 온라인 접속 허용을 고를 수 있는 게임 (가져온 PC 게임)
    private var allowsOnlineToggle: Bool { dish.recipe == .mkxp || dish.recipe == .electron || dish.recipe == .rpgMakerMV }
    /// 인터넷 칸에 보일 것이 있는가: 게임 파일 저장(포켓로그)·온라인 접속·웹 권한
    private var hasInternetSection: Bool {
        dish.knownWeb == .pokerogue || allowsOnlineToggle || (dish.recipe != .mkxp && !(prefs.media ?? [:]).isEmpty)
    }
    private var usesOwnPad: Binding<Bool> {
        Binding(get: { prefs.pad != nil },
                set: { on in store.update(dish.id) { $0.pad = on ? ($0.pad ?? PadPrefs.global()) : nil } })
    }
    private var ownPad: Binding<PadPrefs> {
        Binding(get: { prefs.pad ?? PadPrefs.global() },
                set: { p in store.update(dish.id) { $0.pad = p } })
    }

    private enum SilentChoice: Hashable { case global, on, off }
    @AppStorage(BingsuApp.playInSilentKey) private var globalPlayInSilent = false
    private var silentChoice: Binding<SilentChoice> {
        Binding(get: { prefs.playInSilent.map { $0 ? .on : .off } ?? .global },
                set: { c in
                    store.update(dish.id) { $0.playInSilent = c == .global ? nil : c == .on }
                    BingsuApp.configureAudioSession()
                    NotificationCenter.default.post(name: BingsuApp.soundPrefsChanged, object: nil)
                })
    }

    /// 포켓로그 게임 파일 저장 (BowlScripts.audioCache). 끄면 이 게임 웹 저장소의 Cache API 저장분을 지운다
    private var audioCache: Binding<Bool> {
        Binding(get: { prefs.audioCache != false },
                set: { on in
                    store.update(dish.id) { $0.audioCache = on ? nil : false }
                    if !on {
                        WKWebsiteDataStore(forIdentifier: GlassBowl.storeID(for: dish))
                            .removeData(ofTypes: [WKWebsiteDataTypeFetchCache], modifiedSince: .distantPast) {}
                    }
                    NotificationCenter.default.post(name: BingsuApp.soundPrefsChanged, object: nil)   // 켜진 게임에도 바로
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

                // 저장 데이터: 가장 자주 찾는 것이라 표지 바로 아래 (로컬 게임만)
                if !dish.isRemote { FreezerSection(model: freezerModel) }

                Section {
                    Toggle(isOn: usesOwnPad) {
                        Text("이 게임만의 패드 설정")
                        Text(usesOwnPad.wrappedValue ? "아래 설정은 이 게임에만 적용돼요" : "끄면 설정 > 가상 패드의 값을 따라요")
                    }
                    if usesOwnPad.wrappedValue {
                        PadPrefsControls(prefs: ownPad, onEditLayout: { showEditor = true })
                        Button("기본 설정 값으로 되돌리기") { ownPad.wrappedValue = PadPrefs.global() }
                    }
                    // 터치 조작 (docs/engines/IMPLEMENTATION-touch.md §8): 새 모양 Electron 게임만
                    if dish.isRedBean, let found = dish.electron?.inputStyle {
                        Picker("조작 방식", selection: Binding(get: { prefs.inputStyle.flatMap(ElectronInfo.InputStyle.init(rawValue:)) },
                                                            set: { v in store.update(dish.id) { $0.inputStyle = v?.rawValue } })) {
                            Text("자동 (\(Self.styleName(found)))").tag(ElectronInfo.InputStyle?.none)
                            Text("터치").tag(ElectronInfo.InputStyle?.some(.pointer))
                            Text("가상 패드").tag(ElectronInfo.InputStyle?.some(.pad))
                        }
                        Toggle(isOn: Binding(get: { prefs.keyStrip ?? (prefs.effectiveInputStyle(dish) == .pointer) },
                                             set: { on in store.update(dish.id) { $0.keyStrip = on } })) {
                            Text("키보드 키 보기")
                            Text("Esc·Enter 같은 키를 화면 옆에 띄워요")
                        }
                    }
                    NavigationLink {
                        InputView(dish: dish)
                    } label: {
                        LabeledContent("컨트롤러·키보드", value: KeyMapStore.shared.usesOwn(dish.id) ? "이 게임만" : "모든 게임 설정")
                    }
                    NavigationLink {
                        RumbleSettingsView(dish: dish)
                    } label: {
                        LabeledContent("컨트롤러 진동", value: rumbleSummary)
                    }
                } header: {
                    Text("조작")
                } footer: {
                    if dish.isRedBean, dish.electron?.inputStyle != nil { Text("조작 방식은 게임을 다시 켜면 적용돼요.") }
                }

                Section {
                    Picker("무음 모드에서도 소리 재생", selection: silentChoice) {
                        Text("기본 설정 따르기 (\(globalPlayInSilent ? "켬" : "끔"))").tag(SilentChoice.global)
                        Text("켬").tag(SilentChoice.on)
                        Text("끔").tag(SilentChoice.off)
                    }
                    if dish.recipe == .mkxp {
                        LabeledContent("MIDI 사운드폰트", value: soundFont.map { $0.bundled ? "기본 (\($0.name))" : $0.name } ?? "없음")
                        Button { showSoundFontPicker = true } label: { Label("MIDI 사운드폰트 파일(.sf2) 넣기", systemImage: "square.and.arrow.down") }
                        if soundFont?.bundled == false {
                            Button(role: .destructive) {
                                SoundFontShelf.removeUserFont()
                                soundFont = SoundFontShelf.current
                                soundFontNote = "넣은 사운드폰트를 지웠어요"
                            } label: { Label("넣은 사운드폰트 지우기", systemImage: "trash") }
                        }
                        if let soundFontNote { Text(soundFontNote).font(.footnote).foregroundStyle(.secondary) }
                    }
                    if dish.recipe == .rpgMakerMV {
                        Toggle(isOn: Binding(get: { prefs.pixelSharp != false },
                                             set: { on in store.update(dish.id) { $0.pixelSharp = on ? nil : false } })) {
                            Text("픽셀 선명하게")
                            Text("끄면 부드럽게 보여요. 게임을 다시 켜면 적용돼요")
                        }
                    }
                } header: {
                    Text("소리·화면")
                } footer: {
                    Text("무음 모드 재생을 끄면 다른 앱의 음악과 함께 들려요. 소리 크기는 설정 › 소리·진동에서 정해요."
                         + (dish.recipe == .mkxp ? " MIDI 배경음악은 사운드폰트가 있어야 나요. 넣은 사운드폰트는 이런 게임 모두가 같이 써요." : ""))
                }

                if hasInternetSection {
                    Section {
                        if dish.knownWeb == .pokerogue {
                            Toggle(isOn: audioCache) {
                                Text("게임 파일 저장")
                                Text("한 번 받은 음악·그림을 기기에 두고 바로 써요. 끄면 지워요")
                            }
                        }
                        if allowsOnlineToggle {
                            Toggle(isOn: Binding(get: { prefs.allowOnline != false },
                                                 set: { on in store.update(dish.id) { $0.allowOnline = on ? nil : false } })) {
                                Text("온라인 접속 허용")
                                Text("믿을 수 있는 서버에만 접속하세요. 끄면 인터넷이 없는 것처럼 실행돼요")
                            }
                        }
                        if dish.recipe != .mkxp, let media = prefs.media, !media.isEmpty {
                            ForEach(MediaConsent.Kind.allCases.filter { media[$0.rawValue] != nil }, id: \.self) { kind in
                                Toggle(kind.label, isOn: Binding(get: { prefs.media?[kind.rawValue] == true },
                                                                 set: { on in store.update(dish.id) { p in var m = p.media ?? [:]; m[kind.rawValue] = on; p.media = m } }))
                            }
                            Button("권한 다음에 다시 묻기") { store.update(dish.id) { $0.media = nil } }
                        }
                    } header: {
                        Text("인터넷")
                    } footer: {
                        Text(dish.recipe == .mkxp && allowsOnlineToggle
                             ? "온라인 접속은 게임을 처음 켤 때 적용돼요. 이미 켰다면 빙수를 완전히 닫았다 다시 열어 주세요."
                             : "바꾼 값은 게임을 다시 켜면 적용돼요.")
                    }
                }

                // 게임 중(일시정지 › 이 게임 설정 더 보기)에만: 성능 기록과 진단 정보.
                // 화질·프레임 제한은 일시정지 화면 "화면·성능"에 있어 여기 두지 않는다.
                // 진단 정보는 지금 화면 상태·게임 화면을 같이 담아야 쓸모가 있어 홈에서는 내놓지 않는다
                if let onReceipt {
                    Section {
                        NavigationLink { PerfRecordView(dish: dish) } label: { Text("성능 기록") }
                        Button(action: onReceipt) {
                            HStack { Text("진단 정보").foregroundStyle(Color.primary); Spacer(); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                        }
                    } header: {
                        Text("문제 알리기")
                    } footer: {
                        Text("진단 정보는 문제를 알릴 때 개발자에게 보낼 기술 정보예요. 내용을 보고 직접 공유해요.")
                    }
                }
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
        .onAppear { rumbleSummary = RumbleSettingsView.kind(for: dish) }
        // 창에서 직접 띄우는 선택기 (iPad 에서 시트 안 fileImporter 가 멈추는 문제, GamePicker). 고른 파일은 임시 복사본
        .background(GamePicker(isPresented: $showSoundFontPicker, types: [UTType(filenameExtension: "sf2") ?? .data]) { url in
            guard let url else { return }
            defer { if Delivery.isOwnCopy(url) { try? FileManager.default.removeItem(at: url) } }
            do {
                soundFont = try SoundFontShelf.importFile(url)
                soundFontNote = "사운드폰트를 넣었어요. 게임을 처음 켤 때 적용돼요"
            } catch {
                soundFontNote = "넣지 못했어요: " + error.localizedDescription
            }
        }.frame(width: 0, height: 0))
        .fullScreenCover(isPresented: $showEditor) {
            SpoonLayoutEditor(prefs: ownPad.wrappedValue, target: dish.title,
                              save: { k, a in ownPad.wrappedValue = ownPad.wrappedValue.withLayout(k, a) },
                              onClose: { showEditor = false })
        }
    }

    /// 조작 방식 이름 (화면 문구)
    static func styleName(_ s: ElectronInfo.InputStyle) -> String { s == .pointer ? "터치" : "가상 패드" }
}

/// 이 게임 설정 › 조작 › 컨트롤러 진동: 지금 쓰는 진동표, JSON 가져오기·내보내기, 기본 표로 되돌리기
struct RumbleSettingsView: View {
    let dish: Dish
    @State private var showRumblePicker = false
    @State private var rumbleCard: RumbleCard?
    @State private var rumbleIsOwn = false
    @State private var rumbleNote: String?
    @State private var rumbleExportURL: URL?

    var body: some View {
        Form {
            Section {
                LabeledContent("쓰는 표", value: Self.kind(for: dish))
                LabeledContent("규칙", value: Self.summary(for: dish))
                if dish.recipe == .mkxp || dish.recipe == .rpgMakerMV {
                    LabeledContent("화면 흔들림", value: RumbleSet.forDish(dish).shake ? "울려요" : "울리지 않아요")
                }
                Button { showRumblePicker = true } label: { Label("JSON 가져오기", systemImage: "square.and.arrow.down") }
                if let url = rumbleExportURL {
                    ShareLink(item: url) {
                        Label(rumbleCard == nil ? "새 표 양식 내보내기" : "지금 표 내보내기", systemImage: "square.and.arrow.up")
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
            } footer: {
                Text(dish.recipe == .mkxp || dish.recipe == .rpgMakerMV
                     ? "게임에서 효과음이 나거나 화면이 흔들릴 때 이 표에 맞춰 컨트롤러를 울려요. 형식은 빙수 안내 문서의 진동표 항목(docs/rumble)을 따라요."
                     : "게임에서 효과음이 날 때 이 표에 맞춰 컨트롤러를 울려요. 형식은 빙수 안내 문서의 진동표 항목(docs/rumble)을 따라요.")
            }
        }
        .navigationTitle("컨트롤러 진동")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.accent)
        .onAppear(perform: refreshRumble)
        .fileImporter(isPresented: $showRumblePicker, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            importRumble(url)
        }
    }


    /// 어떤 표를 쓰는지 한마디 (게임 설정 › 조작 줄): "직접 넣은 표" / "게임 전용" / "기본" / "없음"
    static func kind(for dish: Dish) -> String {
        if RumbleShelf.userCard(for: dish.id) != nil { return "직접 넣은 표" }
        if RumbleShelf.bundledCard(for: dish) != nil { return "게임 전용" }
        return RumbleShelf.library.fallback.rules.isEmpty ? "없음" : "기본"
    }

    /// 규칙 요약: "규칙 N개 + 기본 표 M개" (게임 표), 게임 표가 없으면 "포켓몬 공통 기본 표 · 규칙 N개"
    static func summary(for dish: Dish) -> String {
        let own = RumbleShelf.userCard(for: dish.id)
        guard let card = own ?? RumbleShelf.bundledCard(for: dish) else {
            let n = RumbleShelf.library.fallback.rules.count
            return n > 0 ? "포켓몬 공통 기본 표 · \(n)개" : "없음"
        }
        let inherited = card.extends.isEmpty ? "" : " + 기본 표 \(card.extends.count)개"
        return (own != nil ? "" : "\(card.game) · ") + "\(card.ownRules)개" + inherited
    }

    /// 내보낼 파일: 지금 표 파일, 표가 없으면 기본 표를 물려받는 양식
    private func exportURL() -> URL? {
        if let url = rumbleCard?.url { return url }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rumble-template.json")
        let extends = RumbleShelf.fallbackNames.map { "\"\($0)\"" }.joined(separator: ", ")
        let template = """
        {
          "format": 1,
          "game": "\(dish.title.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "").prefix(40))",
          "extends": [\(extends)],
          "rules": [
            { "sound": "hit", "match": "exact", "event": "hit_normal" },
            { "sound": "explosion", "match": "prefix", "strong": 0.9, "weak": 0.4, "duration": 0.3 }
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
