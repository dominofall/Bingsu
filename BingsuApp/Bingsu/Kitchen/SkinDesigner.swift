import SwiftUI

/// 스킨 만들기 (색 스킨). 위에 큰 미리보기, 아래에 이름·색·진하기·모양·글자·버튼별 색. 저장하면 `Documents/Skins/<id>/`.
/// 그림 스킨을 복제하면 PNG 는 그대로 함께 복사되고 여기서는 색 부분만 고친다 (그림은 내보낸 파일에서 바꾼다).
struct SkinDesigner: View {
    enum Start: Identifiable {
        case new(from: String)     // 얼음 등에서 새로 (새 id, 이름 "새 스킨")
        case copy(of: String)      // 복제해서 고치기 (새 id, 이름 "… 사본")
        case edit(String)          // 내 스킨 고치기 (같은 id)
        var id: String {
            switch self { case .new(let s): return "new-" + s; case .copy(let s): return "copy-" + s; case .edit(let s): return "edit-" + s }
        }
    }

    let start: Start
    /// 미리보기 배치·불투명도
    let prefs: PadPrefs
    /// 저장한 스킨 id (취소면 nil)
    let onDone: (String?) -> Void

    @State private var raw = RawSkin(id: nil, name: nil)
    @State private var source: URL?
    @State private var baseImages: [String: SpoonSkin.Picture] = [:]
    @State private var loaded = false
    @State private var error: String?
    @State private var confirmCancel = false
    @State private var original = RawSkin(id: nil, name: nil)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SpoonPreview(prefs: previewPrefs, skin: previewSkin, showZone: false)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Palette.background)
                Form { form }
            }
            .tint(Palette.accent)
            .navigationTitle("스킨 만들기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { if raw != original { confirmCancel = true } else { onDone(nil) } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("저장", action: save).disabled((raw.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .confirmationDialog("고친 내용을 버릴까요?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("버리기", role: .destructive) { onDone(nil) }
            }
            .alert("저장하지 못했어요", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("확인", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .onAppear(perform: load)
    }

    // MARK: 폼

    @ViewBuilder private var form: some View {
        Section {
            TextField("이름", text: Binding(get: { raw.name ?? "" }, set: { raw.name = String($0.prefix(40)) }))
            if !baseImages.isEmpty {
                Text("그림이 든 스킨이에요. 그림이 있는 요소(\(baseImages.keys.sorted().joined(separator: ", ")))는 그림이 먼저 보이고, 여기서는 색만 바꿀 수 있어요. 그림은 내보낸 파일에서 바꾸세요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        Section("색") {
            ColorPicker("테두리·빛", selection: color(\.ink, "#FFFFFF"))
            optionalColor("글자 색 따로", \.text, fallback: raw.colors?.ink ?? "#FFFFFF")
            optionalColor("바탕색 채우기", \.fill, fallback: "#2F62C8")
            ColorPicker("그늘", selection: color(\.shade, "#000000"))
            ColorPicker("눌렸을 때", selection: color(\.press, "#6EC2E8"))
            optionalColor("십자키 색 따로", \.dpad, fallback: raw.colors?.fill ?? "#3B3B3B")
            optionalColor("스틱 색 따로", \.stick, fallback: raw.colors?.fill ?? "#3B3B3B")
        }
        Section("진하기") {
            slider("위쪽 빛", \.fillTop, 0.3, 0...1)
            slider("아래쪽 그늘", \.shadeBottom, 0.3, 0...1)
            slider("테두리", \.rim, 1.1, 0...1.5)
            slider("테두리 굵기", \.lineWidth, 1, 0...4, unit: "pt")
        }
        Section("모양") {
            Picker("둥근 버튼", selection: Binding(get: { raw.shape?.kind == "squircle" }, set: { sq in
                raw.shape = sq ? RawSkin.ShapeSpec(kind: "squircle", corner: raw.shape?.corner ?? 0.4) : RawSkin.ShapeSpec(kind: "circle")
            })) {
                Text("원").tag(false)
                Text("둥근 사각").tag(true)
            }
            .pickerStyle(.segmented)
            if raw.shape?.kind == "squircle" {
                VStack(alignment: .leading) {
                    Text("모서리 둥글기").font(.subheadline)
                    Slider(value: Binding(get: { raw.shape?.corner ?? 0.4 }, set: { raw.shape?.corner = ($0 * 100).rounded() / 100 }), in: 0.2...0.5)
                }
            }
        }
        Section("글자") {
            Picker("글자 세트", selection: Binding(get: { SpoonSkin.LabelStyle(rawValue: raw.labels?.style ?? "") ?? .xbox },
                                                set: { v in ensureLabels(); raw.labels?.style = v.rawValue })) {
                ForEach(SpoonSkin.LabelStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("글꼴", selection: Binding(get: { raw.labels?.font ?? "rounded" }, set: { v in ensureLabels(); raw.labels?.font = v })) {
                ForEach(SpoonSkin.fonts, id: \.0) { Text($0.2).tag($0.0) }
            }
            DisclosureGroup("버튼별 글자") {
                ForEach(SpoonSkin.skinButtons, id: \.self) { b in
                    HStack {
                        Text(PadArrangement.buttonTitle(b, label: nil)).frame(width: 56, alignment: .leading).foregroundStyle(.secondary)
                        TextField("그대로", text: Binding(get: { raw.labels?.overrides?[b.name] ?? "" }, set: { v in
                            ensureLabels()
                            let t = String(v.prefix(8))
                            var o = raw.labels?.overrides ?? [:]
                            o[b.name] = t.isEmpty ? nil : t
                            raw.labels?.overrides = o.isEmpty ? nil : o
                        }))
                    }
                }
            }
        }
        Section {
            ForEach([PadButton.a, .b, .x, .y], id: \.self) { b in
                HStack {
                    Toggle(b.glyph + " 버튼 색", isOn: Binding(get: { raw.buttonColors?[b.name] != nil }, set: { on in
                        var c = raw.buttonColors ?? [:]
                        c[b.name] = on ? (Self.snes[b] ?? "#2F62C8") : nil
                        raw.buttonColors = c.isEmpty ? nil : c
                    }))
                    if raw.buttonColors?[b.name] != nil {
                        ColorPicker("", selection: Binding(get: { Color(skinHex: raw.buttonColors?[b.name] ?? "") ?? .blue },
                                                           set: { raw.buttonColors?[b.name] = $0.skinHex }))
                            .labelsHidden().frame(width: 44)
                    }
                }
            }
            HStack {
                Button("SNES 색으로") { raw.buttonColors = Dictionary(uniqueKeysWithValues: Self.snes.map { ($0.key.name, $0.value) }) }
                Spacer()
                Button("Xbox 색으로") { raw.buttonColors = Dictionary(uniqueKeysWithValues: Self.xbox.map { ($0.key.name, $0.value) }) }
            }
            .buttonStyle(.bordered)
        } header: {
            Text("버튼별 색")
        } footer: {
            Text("버튼마다 바탕색을 정하면 눌렀을 때 그 색이 밝아져요.")
        }
    }

    static let snes: [PadButton: String] = [.a: "#C8343E", .b: "#F2C032", .x: "#2A6BD6", .y: "#3BA55D"]
    static let xbox: [PadButton: String] = [.a: "#5DBB3F", .b: "#E2352B", .x: "#2B6FDB", .y: "#F5C518"]

    private func ensureColors() { if raw.colors == nil { raw.colors = RawSkin.Colors() } }
    private func ensureLabels() { if raw.labels == nil { raw.labels = RawSkin.Labels() } }

    private func color(_ kp: WritableKeyPath<RawSkin.Colors, String?>, _ fallback: String) -> Binding<Color> {
        Binding(get: { Color(skinHex: raw.colors?[keyPath: kp] ?? fallback) ?? .white },
                set: { c in ensureColors(); raw.colors?[keyPath: kp] = c.skinHex })
    }

    private func optionalColor(_ title: String, _ kp: WritableKeyPath<RawSkin.Colors, String?>, fallback: String) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { raw.colors?[keyPath: kp] != nil }, set: { on in ensureColors(); raw.colors?[keyPath: kp] = on ? fallback : nil }))
            if raw.colors?[keyPath: kp] != nil {
                ColorPicker("", selection: color(kp, fallback)).labelsHidden().frame(width: 44)
            }
        }
    }

    private func slider(_ title: String, _ kp: WritableKeyPath<RawSkin.Colors, Double?>, _ def: Double, _ r: ClosedRange<Double>, unit: String? = nil) -> some View {
        let v = raw.colors?[keyPath: kp] ?? def
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(unit.map { String(format: "%.1f", v) + $0 } ?? "\(Int((v * 100).rounded()))%").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { v }, set: { n in ensureColors(); raw.colors?[keyPath: kp] = (n * 100).rounded() / 100 }), in: r)
        }
    }

    // MARK: 미리보기

    private var previewPrefs: PadPrefs {
        var p = prefs
        if p.kind == .oneHand { p.kind = .simple }
        p.opacity = max(p.opacity, 0.6)
        return p
    }

    /// 그림은 처음 한 번 읽어 둔 것을 붙인다 (슬라이더를 움직일 때마다 PNG 를 다시 디코딩하지 않게)
    private var previewSkin: SpoonSkin {
        guard var s = try? SkinShelf.build(raw, folder: nil, strict: false).0 else { return .ice }
        s.images = baseImages
        return s
    }

    // MARK: 읽기 · 저장

    private func load() {
        guard !loaded else { return }
        loaded = true
        let fromID: String
        switch start { case .new(let f): fromID = f; case .copy(let f): fromID = f; case .edit(let f): fromID = f }
        source = SkinShelf.folder(for: fromID)
        if let source, let r = try? SkinShelf.load(folder: source, strict: false) {
            raw = r.raw
            baseImages = r.skin.images
        } else {
            raw = RawSkin(id: nil, name: nil)
        }
        raw.format = SkinShelf.format
        switch start {
        case .new:
            raw = RawSkin(id: Self.newID(), name: "새 스킨", colors: raw.colors, shape: raw.shape, labels: raw.labels)
            baseImages = [:]; source = nil
        case .copy:
            raw.id = Self.newID()
            raw.name = String(((raw.name ?? "스킨") + " 사본").prefix(40))
            raw.author = nil
        case .edit: break
        }
        original = raw
    }

    private func save() {
        do {
            try SkinShelf.saveUser(raw, copyingImagesFrom: baseImages.isEmpty ? nil : source)
            onDone(raw.id)
        } catch {
            self.error = (error as? SkinShelf.Rejection)?.reason ?? error.localizedDescription
        }
    }

    /// `my-<yyyymmdd-hhmmss>`
    static func newID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "my-" + f.string(from: Date())
    }
}
