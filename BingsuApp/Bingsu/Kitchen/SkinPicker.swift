import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.bingsuskin` (zip). project.yml 의 UTExportedTypeDeclarations
    static let bingsuSkin = UTType(exportedAs: "com.minwoo.bingsu.skin", conformingTo: .zip)
}

/// 스킨 고르기 줄: 그 스킨으로 그린 작은 미리보기 썸네일을 가로로. 설정·이 게임 설정(PadPrefsControls)과 일시정지 화면이 쓴다.
/// 줄 끝 "관리…"는 스킨 목록(가져오기·복제·내보내기·지우기)으로 간다 (NavigationStack 안에서만).
struct SkinPicker: View {
    @Binding var prefs: PadPrefs
    var showsManage = true
    var compact = false
    @ObservedObject private var changes = SkinShelf.Changes.shared

    var body: some View {
        let list = SkinShelf.list()
        let current = prefs.effectiveSkin
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: compact ? 8 : 10) {
                    ForEach(list) { s in
                        Button { select(s.id) } label: { SkinThumb(summary: s, prefs: prefs, on: s.id == current, compact: compact) }
                            .buttonStyle(.plain)
                            .id(s.id)
                            .accessibilityLabel("스킨 \(s.name)")
                            .accessibilityAddTraits(s.id == current ? .isSelected : [])
                    }
                    if showsManage {
                        NavigationLink { SkinLibraryView(prefs: $prefs) } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "ellipsis.circle").font(.title2)
                                Text("관리…").font(.caption)
                            }
                            .frame(width: 64, height: compact ? 56 : 74)
                            .foregroundStyle(Palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
    }

    private func select(_ id: String) {
        prefs.skin = id == SpoonSkin.defaultID ? nil : id
    }
}

/// 썸네일 하나: 그 스킨으로 그린 가로 미리보기 + 이름
struct SkinThumb: View {
    let summary: SkinShelf.Summary
    let prefs: PadPrefs
    let on: Bool
    var compact = false

    var body: some View {
        var p = prefs
        p.skin = summary.id
        if p.kind == .oneHand { p.kind = .simple }   // 썸네일은 늘 가로
        p.opacity = max(p.opacity, 0.55)
        return VStack(spacing: 4) {
            SpoonPreview(prefs: p, skin: SkinShelf.skin(id: summary.id), showZone: false)
                .frame(width: compact ? 88 : 112)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Palette.accent : .clear, lineWidth: 2.5))
            Text(summary.name).font(.caption2.weight(on ? .bold : .regular)).lineLimit(1)
                .foregroundStyle(on ? Palette.accent : .primary)
                .frame(width: compact ? 88 : 112)
        }
    }
}

/// 스킨 목록 (설정 › 가상 패드 › 스킨 › 관리…). 앱에 든 스킨과 내 스킨, 고르기·복제해서 고치기·내보내기·지우기, 파일에서 가져오기·새로 만들기
struct SkinLibraryView: View {
    @Binding var prefs: PadPrefs
    @ObservedObject private var changes = SkinShelf.Changes.shared
    @State private var picking = false
    @State private var importing = false
    @State private var importResult: SkinShelf.ImportResult?
    @State private var message: String?
    @State private var designing: SkinDesigner.Start?
    @State private var sharing: ShareItem?
    @State private var deleting: SkinShelf.Summary?

    var body: some View {
        let list = SkinShelf.list()
        List {
            Section {
                Button { picking = true } label: { Label("파일에서 가져오기", systemImage: "square.and.arrow.down") }
                    .disabled(importing)
                Button { designing = .new(from: SpoonSkin.defaultID) } label: { Label("새로 만들기", systemImage: "plus.circle") }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("스킨 파일(.bingsuskin 또는 skin.json 이 든 zip)을 가져오거나, 아무 스킨이나 복제해서 색을 바꿔 보세요. 만드는 법은 빙수 안내 문서의 스킨 항목(docs/skins)에 있어요.")
            }
            Section("앱에 든 스킨") {
                ForEach(list.filter(\.isBundled)) { row($0) }
            }
            let mine = list.filter { !$0.isBundled }
            Section("내 스킨") {
                if mine.isEmpty { Text("아직 없어요").foregroundStyle(.secondary) }
                ForEach(mine) { row($0) }
            }
        }
        .navigationTitle("스킨")
        .navigationBarTitleDisplayMode(.inline)
        .background(GamePicker(isPresented: $picking, types: [.bingsuSkin, .zip]) { url in if let url { importFile(url) } }.frame(width: 0, height: 0))
        .sheet(item: $importResult) { r in
            SkinImportCard(result: r) { useSkin, useLayouts in
                if useSkin, r.installed { prefs.skin = r.id == SpoonSkin.defaultID ? nil : r.id }
                if useLayouts, let l = r.layouts { prefs.layouts = (prefs.layouts ?? [:]).merging(l) { _, new in new } }
                importResult = nil
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $designing) { start in
            SkinDesigner(start: start, prefs: prefs) { savedID in
                designing = nil
                if let savedID { prefs.skin = savedID; message = "저장했어요" }
            }
        }
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .confirmationDialog("이 스킨을 지울까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { s in
            Button("\(s.name) 지우기", role: .destructive) {
                if prefs.effectiveSkin == s.id { prefs.skin = nil }
                SkinShelf.removeUser(s.id)
            }
        } message: { _ in Text("이 스킨을 쓰던 게임은 얼음 스킨으로 보여요.") }
    }

    private func row(_ s: SkinShelf.Summary) -> some View {
        let on = prefs.effectiveSkin == s.id
        return Button { prefs.skin = s.id == SpoonSkin.defaultID ? nil : s.id } label: {
            HStack(spacing: 12) {
                SpoonPreview(prefs: thumbPrefs(s.id), skin: SkinShelf.skin(id: s.id), showZone: false).frame(width: 96)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.body.weight(on ? .semibold : .regular)).foregroundStyle(.primary)
                    if let note = s.note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    let credit = [s.author.map { "만든 사람 \($0)" }, s.license].compactMap { $0 }.joined(separator: " · ")
                    if !credit.isEmpty { Text(credit).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                if on { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
        }
        .contextMenu { actions(s) }
        .swipeActions(edge: .trailing) {
            if !s.isBundled { Button(role: .destructive) { deleting = s } label: { Label("삭제", systemImage: "trash") } }
            Button { export(s) } label: { Label("내보내기", systemImage: "square.and.arrow.up") }.tint(Palette.accent)
        }
        .swipeActions(edge: .leading) {
            Button { designing = .copy(of: s.id) } label: { Label("복제", systemImage: "plus.square.on.square") }.tint(.indigo)
        }
    }

    @ViewBuilder private func actions(_ s: SkinShelf.Summary) -> some View {
        Button { prefs.skin = s.id == SpoonSkin.defaultID ? nil : s.id } label: { Label("고르기", systemImage: "checkmark.circle") }
        Button { designing = .copy(of: s.id) } label: { Label("복제해서 고치기", systemImage: "plus.square.on.square") }
        if !s.isBundled { Button { designing = .edit(s.id) } label: { Label("고치기", systemImage: "slider.horizontal.3") } }
        Button { export(s) } label: { Label("내보내기", systemImage: "square.and.arrow.up") }
        if !s.isBundled { Button(role: .destructive) { deleting = s } label: { Label("삭제", systemImage: "trash") } }
    }

    private func thumbPrefs(_ id: String) -> PadPrefs {
        var p = prefs
        p.skin = id
        if p.kind == .oneHand { p.kind = .simple }
        p.opacity = max(p.opacity, 0.55)
        return p
    }

    private func export(_ s: SkinShelf.Summary) {
        do { sharing = ShareItem(url: try SkinShelf.exportZip(id: s.id)) } catch { message = "내보내지 못했어요: \(error.localizedDescription)" }
    }

    private func importFile(_ url: URL) {
        importing = true
        message = nil
        Task.detached(priority: .userInitiated) {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() }; Delivery.removeInboxCopy(url) }
            let r = Result { try SkinShelf.importZip(at: url) }
            await MainActor.run {
                importing = false
                switch r {
                case .success(let res): importResult = res
                case .failure(let e): message = "가져오지 못했어요: " + ((e as? SkinShelf.Rejection)?.reason ?? e.localizedDescription)
                }
            }
        }
    }
}

extension SkinShelf.ImportResult: Identifiable {}

/// 스킨을 가져온 결과: 넣었다는 알림 + 경고 + (배치가 들어 있으면) 배치도 쓸지. 게임 가져오기 화면과 스킨 목록이 같이 쓴다
struct SkinImportCard: View {
    let result: SkinShelf.ImportResult
    /// (스킨 쓰기, 배치 쓰기). 둘 다 false = 나중에
    let onChoose: (Bool, Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "paintpalette.fill").font(.system(size: 40)).foregroundStyle(Palette.accent)
                Text(title).font(.title3.bold()).multilineTextAlignment(.center)
                SpoonPreview(prefs: PadPrefs(opacity: 0.7, skin: result.id), skin: SkinShelf.skin(id: result.id), showZone: false)
                    .frame(maxWidth: 320)
                if !result.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("일부는 빼고 넣었어요").font(.subheadline.weight(.semibold))
                        ForEach(result.warnings, id: \.self) { Text("· " + $0).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                }
                if let l = result.layouts {
                    Text("이 스킨이 권하는 배치도 쓸까요? (\(Self.layoutSummary(l)))")
                        .font(.subheadline).multilineTextAlignment(.center)
                    if result.installed {
                        Button { onChoose(true, true) } label: { Text("스킨과 배치 쓰기").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).tint(Palette.accent)
                        Button { onChoose(true, false) } label: { Text("스킨만 쓰기").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    } else {
                        Button { onChoose(true, true) } label: { Text("배치 쓰기").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).tint(Palette.accent)
                    }
                } else {
                    Button { onChoose(true, false) } label: { Text("지금 쓰기").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(Palette.accent)
                }
                Button("나중에") { onChoose(false, false) }
            }
            .frame(maxWidth: 420)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var title: String {
        if !result.installed { return "앱에 든 스킨 '\(result.name)'의 배치를 가져왔어요" }
        return "스킨 '\(result.name)'을 \(result.replaced ? "새 판으로 바꿨어요" : "넣었어요")"
    }

    /// "iPhone 가로 · 기본 외 2개"
    static func layoutSummary(_ l: [String: PadArrangement]) -> String {
        let keys = l.keys.sorted()
        guard let first = keys.first else { return "" }
        return PadArrangement.keyTitle(first) + (keys.count > 1 ? " 외 \(keys.count - 1)개" : "")
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// 공유 시트 (내보낸 .bingsuskin)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
