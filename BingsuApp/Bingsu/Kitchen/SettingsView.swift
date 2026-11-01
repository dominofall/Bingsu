import SwiftUI
import UIKit
import GameController

/// 설정 화면. 게임 목록 톱니 버튼과 게임 중 일시정지 시트 "패드 설정"에서 연다.
/// 값은 모두 @AppStorage 라서 바꾸는 즉시 실행 중인 가상 패드에도 반영된다.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// 저장 데이터 관리에서 폴더 이름 대신 게임 이름을 보여 주려고 받는다
    var dishes: [Dish] = []
    var onWillWipe: (String) -> Void = { _ in }

    @AppStorage("spoon.kind") private var kindRaw = PadKind.simple.rawValue
    @AppStorage("spoon.scale") private var scale = 1.0
    @AppStorage("spoon.opacity") private var opacity = 0.55
    @AppStorage("spoon.floatingStick") private var floatingStick = true
    @AppStorage("spoon.showLabels") private var showLabels = false
    @AppStorage("spoon.haptics") private var haptics = true
    @AppStorage("spoon.leftHanded") private var leftHanded = false
    @AppStorage(PadPrefs.skinKey) private var skinID: String?
    @AppStorage(PadPrefs.layoutsKey) private var layoutsData: Data?
    @AppStorage("bingsu.showPerformance") private var showPerformance = false
    @AppStorage(Rumble.key) private var rumble = true
    @AppStorage(Rumble.strengthKey) private var rumbleStrength = 0.7
    @AppStorage(Rumble.btSafeKey) private var rumbleBTSafe = true
    @AppStorage(AudioDiagHUD.key) private var audioDiag = false
    @AppStorage(BingsuApp.playInSilentKey) private var playInSilent = true
    @AppStorage(BingsuApp.gameVolumeKey) private var gameVolume = 1.0
    @AppStorage("bingsu.menuButton") private var menuButtonRaw = MenuButtonPlace.pad.rawValue
    @ObservedObject private var igloo = Igloo.shared
    /// 지금 연결된 실제 컨트롤러 제품명 (식별자 없이)
    @State private var controllers = LongSpoon.connectedNames()
    @State private var showEditor = false

    /// 전역 @AppStorage 값들을 PadPrefs 하나로 묶은 바인딩
    private var globalPad: Binding<PadPrefs> {
        Binding(
            get: { PadPrefs(kind: PadKind(rawValue: kindRaw) ?? .simple, scale: scale, opacity: opacity,
                            floatingStick: floatingStick, showLabels: showLabels, haptics: haptics, leftHanded: leftHanded,
                            skin: skinID.flatMap { $0.isEmpty ? nil : $0 }, layouts: PadPrefs.decodeLayouts(layoutsData)) },
            set: { p in kindRaw = p.kind.rawValue; scale = p.scale; opacity = p.opacity
                   floatingStick = p.floatingStick; showLabels = p.showLabels; haptics = p.haptics
                   leftHanded = p.leftHanded; skinID = p.skin; layoutsData = PadPrefs.encodeLayouts(p.layouts) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PadPrefsControls(prefs: globalPad, onEditLayout: { showEditor = true })
                } header: {
                    Text("가상 패드")
                } footer: {
                    Text("게임마다 다르게 쓰려면 게임 목록에서 게임을 꾹 눌러 \"이 게임 설정\"을 여세요.")
                }

                Section {
                    if controllers.isEmpty {
                        LabeledContent("연결된 컨트롤러", value: "없음")
                    } else {
                        ForEach(controllers.indices, id: \.self) { i in
                            LabeledContent("연결된 컨트롤러", value: controllers[i])
                        }
                    }
                } header: {
                    Text("컨트롤러")
                } footer: {
                    Text("다중 모드 패드(8BitDo·IINE 등)는 스위치(Pro 컨트롤러)·PlayStation·Xbox 모드로 켜면 연결돼요. 서드파티 패드는 앱의 진동 세기를 따르지 않는 경우가 많아요. 그럴 땐 패드 자체 진동 단계로 조절하세요(IINE: 스위치 모드에서 IINE 앱 또는 터보+오른쪽 스틱, PlayStation·Xbox 모드에서는 조절 안 됨). DirectInput·안드로이드 모드는 iOS가 인식하지 않아요. 컨트롤러가 연결되면 가상 패드는 숨겨져요.")
                }
                .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in controllers = LongSpoon.connectedNames() }
                .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in controllers = LongSpoon.connectedNames() }

                Section("게임 중") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("게임 소리 크기", value: "\(Int((gameVolume * 100).rounded()))%")
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { gameVolume }, set: { BingsuApp.setGameVolume($0) }), in: 0...1, step: 0.05)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                        Text("기기 음량과 따로, 모든 게임 소리를 함께 줄여요").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(isOn: $rumble) {
                        Text("컨트롤러 진동")
                        Text("컨트롤러가 있으면 컨트롤러로, 없으면 폰으로 울려요. 게임이 요청한 진동과, 지원하는 게임의 효과음(피격·기절 등)에 맞춰 울려요")
                    }
                    if rumble {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text("진동 세기"); Spacer(); Text("\(Int((rumbleStrength * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit() }
                            // 슬라이더를 움직일 때마다 울리면 잦은 진동이 되므로, 버튼을 눌렀을 때만 지금 세기로 울린다 (2026-10-30 사용자 요청)
                            Slider(value: $rumbleStrength, in: 0.1...1, step: 0.05) { Text("진동 세기") }
                            Button { Rumble.shared.test(intensity: 1) } label: {
                                Label("진동 확인", systemImage: "iphone.radiowaves.left.and.right")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            Text("폰 진동과 정품 컨트롤러에 적용돼요. 서드파티 패드는 아래 컨트롤러 안내를 보세요")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle(isOn: $rumbleBTSafe) {
                            Text("블루투스 이어폰일 때 진동 줄이기")
                            Text("블루투스 컨트롤러 진동과 이어폰 소리가 같은 무선을 나눠 써서 소리가 지직거릴 수 있어요. 켜 두면 이어폰으로 들을 때만 진동을 짧고 드물게 보내요")
                        }
                    }
                    Toggle(isOn: $playInSilent) {
                        Text("무음 모드에서도 소리 재생")
                        Text("끄면 무음 모드일 때 게임 소리가 나지 않고, 다른 앱의 음악과 함께 들려요")
                    }
                    .onChange(of: playInSilent) { _, _ in
                        BingsuApp.configureAudioSession()
                        NotificationCenter.default.post(name: BingsuApp.soundPrefsChanged, object: nil)
                    }
                    Picker("일시정지 버튼 자리", selection: $menuButtonRaw) {
                        ForEach(MenuButtonPlace.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle(isOn: $audioDiag) {
                        Text("소리 문제 진단")
                        Text("게임 화면 아래 구석에 소리 상태·디코딩 시간·마지막 진동 시각을 띄워요. 소리가 깨질 때 무엇과 겹치는지 볼 때만 켜세요")
                    }
                }

                PerfSettingsSection(showPerformance: $showPerformance)

                Section("저장 데이터") {
                    NavigationLink("저장 데이터 관리") { SavedDataView(dishes: dishes, onWillWipe: onWillWipe) }
                }
                CloudSyncSection(igloo: igloo)

                Section("정보") {
                    LabeledContent("버전", value: Self.versionText)
                    NavigationLink("오픈소스 라이선스") { LicensesView() }
                }
            }
            .tint(Palette.accent)
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .fullScreenCover(isPresented: $showEditor) {
            SpoonLayoutEditor(prefs: globalPad.wrappedValue,
                              save: { k, a in globalPad.wrappedValue = globalPad.wrappedValue.withLayout(k, a) },
                              onClose: { showEditor = false })
        }
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// 가상 패드 조작부: 미리보기 + 종류·크기·불투명도·스틱·설명·진동. 전역 설정과 게임별 설정이 같이 쓴다.
struct PadPrefsControls: View {
    @Binding var prefs: PadPrefs
    /// "배치 편집" (전역 또는 이 게임). nil 이면 버튼을 숨긴다
    var onEditLayout: (() -> Void)? = nil

    var body: some View {
        SpoonPreview(prefs: prefs)
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        Picker("종류", selection: $prefs.kind) {
            ForEach(PadKind.allCases, id: \.self) { k in Text(k.label).tag(k) }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("스킨")
            SkinPicker(prefs: $prefs)
        }
        if let onEditLayout {
            Button(action: onEditLayout) {
                HStack {
                    Label("배치 편집", systemImage: "hand.draw")
                    Spacer()
                    Text(layoutStatus).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        if prefs.kind == .oneHand {
            Text("세로로 들었을 때 엄지 하나로 쓰는 배치예요. 가로로 돌리면 기본 배치로 바뀌어요.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("쓰는 손", selection: $prefs.leftHanded) {
                Text("오른손").tag(false)
                Text("왼손").tag(true)
            }
            .pickerStyle(.segmented)
        }
        sliderRow("크기", value: $prefs.scale, in: 0.8...1.3)
        sliderRow("불투명도", value: $prefs.opacity, in: 0.25...0.9)
        Toggle(isOn: $prefs.floatingStick) {
            Text("움직이는 스틱")
            Text("왼쪽 화면 어디든 엄지를 대면 그 자리에 스틱이 생겨요")
        }
        .disabled(!prefs.providesStick())
        Toggle("버튼 설명 표시", isOn: $prefs.showLabels)
        Toggle("진동", isOn: $prefs.haptics)
    }

    /// 이 기기에서 직접 바꾼 배치가 몇 개인지
    private var layoutStatus: String {
        let prefix = UIDevice.current.userInterfaceIdiom == .pad ? "pad." : "phone."
        let n = prefs.layouts?.keys.filter { $0.hasPrefix(prefix) }.count ?? 0
        return n == 0 ? "기본 배치" : "직접 바꾼 배치 \(n)개"
    }

    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

/// 현재 설정으로 계산한 가상 패드 배치를 기기 화면 비율로 축소해 그린다. 터치는 받지 않는다.
/// 가로 iPhone(또는 iPad) 기준, 한손은 세로 화면으로 보여 준다.
/// 사용자 배치(`prefs.layouts`)가 있으면 그것으로 그린다.
struct SpoonPreview: View {
    let prefs: PadPrefs
    /// nil 이면 prefs 의 스킨 (스킨 고르기 썸네일·스킨 만들기는 직접 준다)
    var skin: SpoonSkin? = nil
    /// 세로로 보일지 (한손은 늘 세로)
    var portrait = false
    var showZone = true
    private var kind: PadKind { prefs.kind }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// 기준 화면(pt)과 안전 영역
    private var screen: CGSize {
        let s = isPad ? CGSize(width: 1376, height: 1032) : CGSize(width: 852, height: 393)
        return isPortrait ? CGSize(width: s.height, height: s.width) : s
    }
    private var isPortrait: Bool { portrait || kind == .oneHand }
    private var safe: SpoonLayout.Insets {
        if isPad { return (24, 0, 20, 0) }
        return isPortrait ? (59, 0, 34, 0) : (0, 59, 21, 59)
    }

    var body: some View {
        let screen = screen
        let l = SpoonLayout.make(prefs: prefs, size: screen, safe: safe)
        GeometryReader { geo in
            let k = geo.size.width / screen.width
            SpoonFace(layout: l, opacity: prefs.opacity, scale: prefs.scale, skin: skin ?? SkinShelf.skin(for: prefs), showZone: showZone)
                .frame(width: screen.width, height: screen.height)
                .scaleEffect(k, anchor: .topLeading)
        }
        .aspectRatio(screen.width / screen.height, contentMode: .fit)
        .frame(maxHeight: isPortrait ? 260 : nil)
        .background(
            LinearGradient(colors: [Color(red: 0.12, green: 0.25, blue: 0.58), Color(red: 0.06, green: 0.08, blue: 0.13)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
        .accessibilityLabel("가상 패드 미리보기")
    }
}

/// RPG Maker XP 엔진(BrassBowl.framework)에 같이 든 라이브러리 목록. 프레임워크 안 licenses.json 을 읽는다
enum BrassBowlNotice {
    struct Item: Decodable, Identifiable {
        let name: String
        let license: String
        let text: String
        var id: String { name }
    }

    static let forkURL = URL(string: "https://github.com/mateo-m/mkxp-z-apple-mobile")!
    /// 위에 따로 적은 두 항목
    static let shownAbove: Set<String> = ["mkxp-z-apple-mobile", "mkxp-z"]

    static var frameworkURL: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("BrassBowl.framework", isDirectory: true)
    }

    static let bundled: [Item] = {
        guard let u = frameworkURL?.appendingPathComponent("licenses.json"),
              let d = try? Data(contentsOf: u) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: d)) ?? []
    }()

    /// 묶어 넣은 엔진 판(빌드 때 Info.plist 에 적힘)
    static var engineCommit: String {
        guard let u = frameworkURL, let b = Bundle(url: u),
              let c = b.object(forInfoDictionaryKey: "BrassBowlEngineCommit") as? String else { return "v9" }
        return "v9 · " + c
    }
}

/// 오픈소스 라이선스 (같이 들어 있는 것)
struct LicensesView: View {
    /// 빙수 자신의 소스. 앱이 GPL-3.0 이라 받는 사람이 같은 소스를 구할 수 있게 주소를 보인다
    static let sourceURL = URL(string: "https://github.com/dominofall/Bingsu")!
    /// 이 앱과 같은 판의 소스: 배포할 때마다 공개 저장소에 `v<버전>-<빌드>` 태그(예: v0.2.0-17)를 단다
    static var versionSourceURL: URL {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String, let b = info?["CFBundleVersion"] as? String,
              !v.isEmpty, !b.isEmpty else { return sourceURL }
        return sourceURL.appendingPathComponent("tree").appendingPathComponent("v\(v)-\(b)")
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("빙수 \(SettingsView.versionText)").font(.headline)
                    Text("GNU GPL 3.0 · 누구나 소스를 받아 고치고 다시 배포할 수 있어요").font(.subheadline).foregroundStyle(.secondary)
                    Link("이 버전의 소스 코드", destination: Self.versionSourceURL).font(.subheadline)
                }
                .padding(.vertical, 2)
                NavigationLink("GNU GPL 3.0 전문") { BundledTextView(title: "GNU GPL 3.0", file: "LICENSE") }
                NavigationLink("서드파티 라이선스 전문") { BundledTextView(title: "서드파티 라이선스", file: "THIRD_PARTY_LICENSES.md") }
            } header: {
                Text("빙수")
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("@wasm-audio-decoders/ogg-vorbis 0.1.20").font(.headline)
                    Text("MIT License · 게임 소리(ogg) 재생에 사용").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("libvorbis · libogg").font(.headline)
                    Text("BSD-3-Clause (Xiph.Org) · 위 디코더 안에 들어 있음").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ZIPFoundation 0.9.20").font(.headline)
                    Text("MIT License · 게임 파일(zip) 풀기에 사용").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SwiftGlass 26.0.1").font(.headline)
                    Text("MIT License · 일시정지 화면과 게임 칩의 유리 효과에 사용").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Phaser 3.80.1").font(.headline)
                    Text("MIT License · 기본 게임 \"Bingsu\"의 그림에 사용").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ZzFX 1.4.0").font(.headline)
                    Text("MIT License · 기본 게임 \"Bingsu\"의 효과음에 사용").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            // 패드 스킨: 앱에 든 스킨 중 다른 사람이 만든 것 (PR 로 들어온 스킨의 작성자·라이선스)
            let credited = SkinShelf.list().filter { $0.isBundled && $0.author != nil }
            if !credited.isEmpty {
                Section("패드 스킨") {
                    ForEach(credited) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.name).font(.headline)
                            Text("\(s.author ?? "") · \(s.license ?? "라이선스 없음")").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            // RPG Maker XP 엔진(BrassBowl.framework). 포크의 추가 조건(ADDITIONAL-TERMS.md 1항)에 따라
            // 저작자 표시를 다른 고지와 같은 크기로 보이고, 주소는 눌러 열 수 있게 둔다
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("mkxp-z-apple-mobile, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/mkxp-z-apple-mobile").font(.headline)
                    Text("GPL-3.0 (추가 조건 있음) · RPG Maker XP 게임 실행에 사용").font(.subheadline).foregroundStyle(.secondary)
                    Link("소스 코드 (\(BrassBowlNotice.engineCommit))", destination: BrassBowlNotice.forkURL).font(.subheadline)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("mkxp-z").font(.headline)
                    Text("GPL-2.0 or later · Copyright (C) 2013-2024 Jonas Kulla, Splendide Imaginarius and contributors").font(.subheadline).foregroundStyle(.secondary)
                    Link("소스 코드", destination: URL(string: "https://github.com/mkxp-z/mkxp-z")!).font(.subheadline)
                }
                .padding(.vertical, 2)
                ForEach(BrassBowlNotice.bundled.filter { !BrassBowlNotice.shownAbove.contains($0.name) }) { item in
                    NavigationLink {
                        ScrollView {
                            Text(item.text).font(.footnote.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                        .navigationTitle(item.name)
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.headline)
                            Text(item.license).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("RPG Maker XP 엔진")
            } footer: {
                Text("빙수는 RPG Maker XP 게임을 돌리려고 mkxp-z-apple-mobile 을 고치지 않은 채 묶어 넣어요. 엔진은 GNU GPL 이라 누구나 위 주소에서 같은 판의 소스를 받을 수 있어요. 엔진을 묶는 빙수 쪽 빌드 방법은 빙수 소스의 BingsuApp/BrassBowl 폴더에 있어요.")
            }
        }
        .navigationTitle("오픈소스 라이선스")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 앱에 같이 넣은 라이선스 문서(LICENSE·THIRD_PARTY_LICENSES.md)를 그대로 보인다
struct BundledTextView: View {
    let title: String
    let file: String

    var body: some View {
        ScrollView {
            Text(text).font(.footnote.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var text: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: nil),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "\(file) 를 찾지 못했어요. \(LicensesView.sourceURL.absoluteString) 에서 볼 수 있어요." }
        return s
    }
}

/// 설정 › 클라우드 동기화: 끔 / iCloud / Google Drive 중 하나. Drive 면 연결·해제 버튼과 연결 표시.
/// 화면에는 "연결"만 쓴다 ("로그인" 아님 — 앱 계정이 아니라 저장소 연결, 심사 4.8)
struct CloudSyncSection: View {
    @ObservedObject var igloo: Igloo
    @State private var changed = false
    @State private var confirmDisconnect = false
    @State private var connectError: String?

    private var choices: [IglooShelfKind] { igloo.drive.isConfigured || igloo.backend == .drive ? IglooShelfKind.allCases : [.off, .icloud] }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("클라우드 동기화")
                    Text(igloo.statusText).font(.footnote).foregroundStyle(.secondary)
                }
                Picker("클라우드 동기화", selection: Binding(get: { igloo.backend }, set: { k in changed = true; igloo.setBackend(k) })) {
                    ForEach(choices, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if igloo.backend == .drive {
                if igloo.drive.isConnected, let label = igloo.accountLabel ?? igloo.drive.accountLabel {
                    LabeledContent("Google Drive", value: label)
                    Button("연결 해제", role: .destructive) { confirmDisconnect = true }
                        .tint(.red)
                        // 확인 창은 이 버튼에 붙인다 (Section 에 붙이면 행마다 퍼지고 엉뚱한 자리에 뜬다)
                        .confirmationDialog("Google Drive 연결을 해제할까요?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                            Button("연결 해제", role: .destructive) { Task { await igloo.disconnectDrive() } }
                            Button("취소", role: .cancel) {}
                        } message: {
                            Text("이 기기의 연결 정보만 지워요. 이 기기와 Google Drive 의 저장 데이터는 그대로 남아요. Drive 에 둔 사본은 Google Drive 설정 › 앱 관리에서 지울 수 있어요.")
                        }
                } else {
                    Button { Task { connectError = await igloo.connectDrive() } } label: {
                        HStack {
                            Label("Google Drive 연결", systemImage: "link")
                            if igloo.connecting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(igloo.connecting)
                    .alert("Google Drive 를 연결하지 못했어요", isPresented: Binding(get: { connectError != nil }, set: { if !$0 { connectError = nil } })) {
                        Button("확인", role: .cancel) {}
                    } message: { Text(connectError ?? "") }
                }
            }
            if igloo.enabled {
                Button("지금 동기화") { Task { await igloo.syncAll() } }
                    .disabled(igloo.syncing || [.noAccount, .unavailable].contains(igloo.availability))
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(footer)
                if !igloo.drive.isConfigured && igloo.backend != .drive { Text("Google Drive 는 준비 중이에요.") }
                if changed { Text("다른 저장소로 바꾸면 처음 맞출 때 양쪽이 다르면 물어봐요.") }
            }
        }
    }

    private var footer: String {
        switch igloo.backend {
        case .off: return "켜면 PC용 게임 저장 데이터와 게임별 설정을 다른 iPhone·iPad 와 이어서 써요. 브라우저 게임은 각 사이트 계정으로 이어져요."
        case .icloud: return "같은 Apple ID 의 iPhone·iPad 에서 PC용 게임 저장 데이터와 게임별 설정을 이어서 써요. 브라우저 게임은 각 사이트 계정으로 이어져요."
        case .drive: return "같은 Google 계정을 연결한 iPhone·iPad 에서 PC용 게임 저장 데이터와 게임별 설정을 이어서 써요. Google Drive 의 앱 전용 공간에 두어 Drive 목록에는 보이지 않고, 빙수 말고는 읽을 수 없어요."
        }
    }
}
