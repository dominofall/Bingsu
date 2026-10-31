import SwiftUI
import UIKit

/// 가상 패드 배치 편집 (화면 "배치 편집"). 지금 기기 방향 하나의 배치를 끌어 옮기고, 크기를 바꾸고, 요소를 더하거나 숨긴다.
/// 여는 곳: 일시정지 화면 › 조작 (이 게임, 멈춘 게임 위), 설정 › 가상 패드 (모든 게임), 이 게임 설정 › 가상 패드.
/// 저장은 `PadPrefs.layouts[<기기>.<방향>.<종류>]` 하나 (`PadArrangement`). 한손+왼손은 거울로 보여 주고 오른손 기준으로 저장한다.
/// 그리기는 게임과 같은 `SpoonFace`(지금 스킨·불투명도)에 선택 테두리·안내선만 더한다.
struct SpoonLayoutEditor: View {
    enum Backdrop { case game, ice }

    /// 편집을 시작할 때의 패드 설정 (종류·크기·스킨·불투명도·저장된 배치)
    let prefs: PadPrefs
    var backdrop = Backdrop.ice
    /// 어디에 저장하는지 ("모든 게임" 또는 게임 이름)
    var target = "모든 게임"
    /// 키에 배치를 저장 (nil = 그 키를 지워 기본 배치로)
    let save: (String, PadArrangement?) -> Void
    let onClose: () -> Void

    @AppStorage("bingsu.menuButton") private var menuButtonRaw = MenuButtonPlace.pad.rawValue

    @State private var key: String?
    @State private var working = PadArrangement(elements: [])
    @State private var undo: [PadArrangement] = []
    @State private var redo: [PadArrangement] = []
    @State private var dirty = false
    @State private var selected: String?
    /// 저장한 배치 (열 때 prefs.layouts, 저장·기본 배치로 하면 바뀜)
    @State private var saved: [String: PadArrangement] = [:]
    @State private var loadedOnce = false

    // 끌기
    @State private var dragID: String?
    @State private var dragStart: CGPoint = .zero
    @State private var preDrag: PadArrangement?
    @State private var guideX: [CGFloat] = []
    @State private var guideY: [CGFloat] = []

    // 알림·시트
    @State private var pendingKey: String?
    @State private var showAdd = false
    @State private var confirmReset = false
    @State private var confirmCancel = false
    @State private var sharing: ShareItem?
    @State private var exportError: String?

    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private static let maxUndo = 50

    private var idiom: UIUserInterfaceIdiom { UIDevice.current.userInterfaceIdiom }
    private var k: CGFloat { CGFloat(prefs.scale) * SpoonLayout.deviceFactor(idiom) }
    private var skin: SpoonSkin { SkinShelf.skin(for: prefs) }
    /// 한손 + 왼손 + 세로: 거울로 보여 준다
    private func mirrors(_ key: String) -> Bool { prefs.kind == .oneHand && prefs.leftHanded && key.contains(".portrait.") }
    private var orbInPad: Bool { prefs.kind == .oneHand || (MenuButtonPlace(rawValue: menuButtonRaw) ?? .pad) == .pad }

    var body: some View {
        GeometryReader { geo in
            let ins = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + ins.leading + ins.trailing, height: geo.size.height + ins.top + ins.bottom)
            let safe: SpoonLayout.Insets = (ins.top, ins.leading, ins.bottom, ins.trailing)
            let newKey = PadArrangement.key(idiom: idiom, landscape: full.width >= full.height, kind: prefs.kind)
            let layout = SpoonLayout.resolve(working, size: full, safe: safe, k: k, floatingStick: prefs.floatingStick)
            ZStack(alignment: .topLeading) {
                backdropView(full: full, safe: safe, layout: layout)
                SpoonFace(layout: layout, opacity: prefs.opacity, scale: prefs.scale, skin: skin, showZone: false)
                if let c = layout.orbCenter { SnowOrb(size: 32, skin: skin).position(c).allowsHitTesting(false) }
                guides(full)
                if let sel = selected, let f = frame(sel, layout) {
                    RoundedRectangle(cornerRadius: min(f.width, f.height) / 2 + 6, style: .continuous)
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, dash: [7, 4]))
                        .frame(width: f.width + 12, height: f.height + 12)
                        .position(x: f.midX, y: f.midY)
                        .allowsHitTesting(false)
                }
                accessibilityElements(layout, full: full, safe: safe)
                // 끌기·탭은 화면 전체에서 받고 요소는 자리로 판정 (SpoonLayout 의 터치 영역과 같은 계산)
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("editor"))
                        .onChanged { v in dragChanged(v, layout: layout, full: full, safe: safe) }
                        .onEnded { v in dragEnded(v) })
                    .accessibilityHidden(true)
                panel(layout: layout, full: full, safe: safe)
            }
            .coordinateSpace(name: "editor")
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
            .onAppear { keyChanged(newKey, full: full, safe: safe) }
            .onChange(of: newKey) { _, k in keyChanged(k, full: full, safe: safe) }
            .sheet(isPresented: $showAdd) { addSheet(full: full, safe: safe, layout: layout) }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .alert(pendingTitle, isPresented: Binding(get: { pendingKey != nil }, set: { _ in })) {
            Button("저장") { commitPending(save: true) }
            Button("버리기", role: .destructive) { commitPending(save: false) }
        } message: { Text("방향이 바뀌었어요. 저장하지 않으면 바꾼 것은 없어져요.") }
        .alert("기본 배치로 되돌릴까요?", isPresented: $confirmReset) {
            Button("기본 배치로", role: .destructive, action: resetToDefault)
            Button("취소", role: .cancel) {}
        } message: { Text("\(keyLabel) 배치를 지우고 빙수가 정한 자리로 돌아가요.") }
        .confirmationDialog("바꾼 배치를 버릴까요?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("버리고 닫기", role: .destructive, action: onClose)
        }
        .alert("내보내지 못했어요", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
    }

    // MARK: 배경

    @ViewBuilder private func backdropView(full: CGSize, safe: SpoonLayout.Insets, layout: SpoonLayout) -> some View {
        switch backdrop {
        case .game:
            // 멈춘 게임이 뒤에 그대로 보인다. 패드가 잘 보이게 아주 옅게만 어둡게
            Color.black.opacity(0.28).frame(width: full.width, height: full.height)
        case .ice:
            LinearGradient(colors: [Color(red: 0.12, green: 0.25, blue: 0.58), Color(red: 0.06, green: 0.08, blue: 0.13)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: full.width, height: full.height)
            // 16:9 게임 자리 (게임 화면과 같은 계산: 가로는 높이를 채운 가운데, 세로는 패드 위 남는 곳)
            let r = full.width >= full.height ? BowlContainerView.landscapeRect(W: full.width, H: full.height)
                : BowlContainerView.portraitRect(W: full.width, H: full.height, top: safe.top, padTop: layout.topEdge,
                                                 orbInPad: orbInPad, padShown: true)
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
                .overlay(Text("게임 화면").font(.footnote).foregroundStyle(.white.opacity(0.45)))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func guides(_ full: CGSize) -> some View {
        ForEach(guideX, id: \.self) { x in
            Rectangle().fill(Palette.ribbon.opacity(0.85)).frame(width: 1, height: full.height).position(x: x, y: full.height / 2)
        }
        ForEach(guideY, id: \.self) { y in
            Rectangle().fill(Palette.ribbon.opacity(0.85)).frame(width: full.width, height: 1).position(x: full.width / 2, y: y)
        }
    }

    /// 보이스오버: 요소 이름과 자리만 ("A 버튼, 오른쪽 아래에서 50, 96")
    private func accessibilityElements(_ layout: SpoonLayout, full: CGSize, safe: SpoonLayout.Insets) -> some View {
        ForEach(working.elements) { e in
            if let f = frame(e.id, layout) {
                Color.clear.frame(width: f.width, height: f.height).position(x: f.midX, y: f.midY)
                    .accessibilityElement()
                    .accessibilityLabel("\(e.title), \(Self.anchorTitle(e.anchor))에서 \(Int(e.x.rounded())), \(Int(e.y.rounded()))")
                    .accessibilityAddTraits(selected == e.id ? [.isSelected, .isButton] : .isButton)
                    .accessibilityAction { selected = e.id }
                    .allowsHitTesting(false)
            }
        }
    }

    static func anchorTitle(_ a: PadArrangement.Anchor) -> String {
        switch a {
        case .topLeft: return "왼쪽 위"; case .topCenter: return "가운데 위"; case .topRight: return "오른쪽 위"
        case .bottomLeft: return "왼쪽 아래"; case .bottomCenter: return "가운데 아래"; case .bottomRight: return "오른쪽 아래"
        }
    }

    // MARK: 도구 막대

    private var keyLabel: String {
        guard let key else { return "" }
        let p = key.split(separator: ".").map(String.init)
        guard p.count == 3 else { return key }
        return "\(p[1] == "portrait" ? "세로" : "가로") · \(PadKind(rawValue: p[2])?.shortLabel ?? p[2])"
    }

    private var pendingTitle: String { "바꾼 \(keyLabel) 배치를 저장할까요?" }

    @ViewBuilder private func panel(layout: SpoonLayout, full: CGSize, safe: SpoonLayout.Insets) -> some View {
        // 고른 요소가 위쪽에 있으면 막대를 아래로 (가리지 않게). 끄는 동안은 흐리게, 터치는 통과
        let selCenter = selected.flatMap { frame($0, layout) }.map { CGPoint(x: $0.midX, y: $0.midY) }
        let atBottom = (selCenter?.y ?? full.height) < full.height * 0.42
        let width = min(full.width - safe.left - safe.right - 16, 560)
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button("취소") { if dirty { confirmCancel = true } else { onClose() } }
                    .buttonStyle(.bordered).fixedSize()
                iconButton("arrow.uturn.backward", "되돌리기", disabled: undo.isEmpty, action: undoStep)
                iconButton("arrow.uturn.forward", "다시 실행", disabled: redo.isEmpty, action: redoStep)
                Spacer(minLength: 4)
                VStack(spacing: 1) {
                    Text(keyLabel).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(key.map { mirrors($0) } == true ? "\(target) · 왼손" : target).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
                Spacer(minLength: 4)
                iconButton("plus", "요소 추가", disabled: false) { showAdd = true }
                Menu {
                    Button { mutate { $0 = $0.flippedForOtherHand() } } label: { Label("좌우 뒤집기", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    Button(role: .destructive) { confirmReset = true } label: { Label("기본 배치로", systemImage: "arrow.counterclockwise") }
                    Button { exportLayouts() } label: { Label("배치 내보내기", systemImage: "square.and.arrow.up") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).frame(width: 36, height: 36)
                }
                .accessibilityLabel("더 보기")
                Button("저장", action: saveAndClose).buttonStyle(.borderedProminent).tint(Palette.accent).fixedSize()
            }
            if let sel = selected, let i = working.elements.firstIndex(where: { $0.id == sel }) {
                elementTools(i)
            } else {
                Text("요소를 끌어 옮기고, 눌러서 크기를 바꾸거나 숨겨요. \(full.width >= full.height ? "세로" : "가로") 배치는 기기를 돌려서 편집해요.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(dragID != nil && dragID != "" ? 0.35 : 1)
        .allowsHitTesting(dragID == nil)
        .tint(Palette.accent)
        .modifier(PanelPlacement(atBottom: atBottom, full: full, safe: safe))
    }

    private func iconButton(_ name: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.body.weight(.semibold)).frame(width: 34, height: 34) }
            .disabled(disabled)
            .accessibilityLabel(label)
    }

    @ViewBuilder private func elementTools(_ i: Int) -> some View {
        let e = working.elements[i]
        HStack(spacing: 10) {
            Text(e.title).font(.footnote.weight(.semibold)).lineLimit(1).fixedSize()
            if e.type != .orb {
                Slider(value: Binding(get: { e.radius }, set: { v in
                    guard working.elements.indices.contains(i) else { return }
                    working.elements[i].radius = (v * 2).rounded() / 2; dirty = true
                }), in: e.radiusRange) { editing in if editing { pushUndo() } }
                .accessibilityLabel("크기")
            } else {
                Spacer()
            }
            Button(role: .destructive) { mutate { $0.elements.removeAll { $0.id == e.id } }; selected = nil } label: {
                Text("숨기기").font(.footnote)
            }
            .buttonStyle(.bordered)
        }
        if e.type == .stick || e.pill == true {
            HStack(spacing: 14) {
                if e.type == .stick {
                    Toggle("움직이는 스틱", isOn: Binding(get: { e.floating ?? (e.isRightStick ? false : prefs.floatingStick) },
                                                     set: { v in mutate { $0.elements[i].floating = v } }))
                        .font(.footnote).fixedSize()
                }
                if e.pill == true {
                    Toggle("넓게", isOn: Binding(get: { (e.stretch ?? 1.3) > 2 }, set: { v in mutate { $0.elements[i].stretch = v ? 2.7 : 1.3 } }))
                        .font(.footnote).fixedSize()
                }
                Spacer()
            }
        }
    }

    // MARK: 끌기

    /// 자리 판정: 손가락이 닿은 곳에서 가장 가까운 요소 (버튼은 넓힌 터치 영역, 십자키·스틱은 반지름 조금 넘게, 눈송이는 22pt)
    private func hit(_ p: CGPoint, _ layout: SpoonLayout) -> String? {
        var best: (String, CGFloat)?
        func consider(_ id: String, _ c: CGPoint, _ inside: Bool) {
            guard inside else { return }
            let d = hypot(p.x - c.x, p.y - c.y)
            if best == nil || d < best!.1 { best = (id, d) }
        }
        for s in layout.buttons { consider("button." + s.button.name, s.center, s.contains(p)) }
        if let c = layout.dpadCenter { consider("dpad", c, hypot(p.x - c.x, p.y - c.y) <= layout.dpadRadius * 1.1) }
        for s in [layout.leftStick, layout.rightStick].compactMap({ $0 }) {
            consider(s.isRight ? "stick.right" : "stick.left", s.restCenter, hypot(p.x - s.restCenter.x, p.y - s.restCenter.y) <= s.baseRadius * 1.15)
        }
        if let c = layout.orbCenter { consider("orb", c, hypot(p.x - c.x, p.y - c.y) <= 24) }
        return best?.0
    }

    /// 요소의 화면 틀 (선택 테두리·안내선·자리 찾기)
    private func frame(_ id: String, _ layout: SpoonLayout) -> CGRect? {
        func box(_ c: CGPoint, _ hw: CGFloat, _ hh: CGFloat) -> CGRect { CGRect(x: c.x - hw, y: c.y - hh, width: hw * 2, height: hh * 2) }
        switch id {
        case "dpad": return layout.dpadCenter.map { box($0, layout.dpadRadius, layout.dpadRadius) }
        case "stick.left": return layout.leftStick.map { box($0.restCenter, $0.baseRadius, $0.baseRadius) }
        case "stick.right": return layout.rightStick.map { box($0.restCenter, $0.baseRadius, $0.baseRadius) }
        case "orb": return layout.orbCenter.map { box($0, 16, 16) }
        default:
            guard let s = layout.buttons.first(where: { "button." + $0.button.name == id }) else { return nil }
            return box(s.center, s.width / 2, s.radius)
        }
    }

    private func dragChanged(_ v: DragGesture.Value, layout: SpoonLayout, full: CGSize, safe: SpoonLayout.Insets) {
        if dragID == nil {
            guard let id = hit(v.startLocation, layout), let f = frame(id, layout) else {
                dragID = ""; selected = nil; return
            }
            dragID = id; selected = id
            dragStart = CGPoint(x: f.midX, y: f.midY)
            preDrag = working
            haptic.impactOccurred(intensity: 0.7)
            return
        }
        guard let id = dragID, !id.isEmpty, let f = frame(id, layout),
              hypot(v.translation.width, v.translation.height) > 3 || preDrag != working else { return }
        // 4pt 격자 → 다른 요소의 중심 x·y 와 6pt 안이면 맞춤 → 화면 가로 가운데 → 안전 영역 안
        var c = CGPoint(x: dragStart.x + v.translation.width, y: dragStart.y + v.translation.height)
        c.x = (c.x / 4).rounded() * 4; c.y = (c.y / 4).rounded() * 4
        var gx: [CGFloat] = [], gy: [CGFloat] = []
        for other in working.elements where other.id != id {
            guard let o = frame(other.id, layout) else { continue }
            if gx.isEmpty, abs(c.x - o.midX) < 6 { c.x = o.midX; gx.append(o.midX) }
            if gy.isEmpty, abs(c.y - o.midY) < 6 { c.y = o.midY; gy.append(o.midY) }
        }
        if gx.isEmpty, abs(c.x - full.width / 2) < 6 { c.x = full.width / 2; gx.append(full.width / 2) }
        let hw = f.width / 2, hh = f.height / 2
        c.x = min(max(c.x, safe.left + hw), full.width - safe.right - hw)
        c.y = min(max(c.y, safe.top + hh), full.height - safe.bottom - hh)
        if gx != guideX || gy != guideY {
            if !gx.isEmpty || !gy.isEmpty { UISelectionFeedbackGenerator().selectionChanged() }
            guideX = gx; guideY = gy
        }
        place(id, at: c, full: full, safe: safe)
    }

    private func dragEnded(_ v: DragGesture.Value) {
        if let pre = preDrag, pre != working {
            undo.append(pre); if undo.count > Self.maxUndo { undo.removeFirst() }
            redo = []; dirty = true
            haptic.impactOccurred(intensity: 0.4)
        }
        dragID = nil; preDrag = nil; guideX = []; guideY = []
    }

    /// 화면 자리 → 기준점은 그 자리에서 가장 가까운 것으로 다시 골라 배치 포인트로
    private func place(_ id: String, at c: CGPoint, full: CGSize, safe: SpoonLayout.Insets) {
        guard let i = working.elements.firstIndex(where: { $0.id == id }) else { return }
        let a = PadArrangement.Anchor.nearest(to: c, size: full)
        let o = a.point(size: full, safe: safe)
        working.elements[i].anchor = a
        working.elements[i].x = Double((c.x - o.x) / k)
        working.elements[i].y = Double((c.y - o.y) / k)
    }

    // MARK: 되돌리기

    private func pushUndo() {
        undo.append(working); if undo.count > Self.maxUndo { undo.removeFirst() }
        redo = []; dirty = true
    }

    private func mutate(_ change: (inout PadArrangement) -> Void) {
        pushUndo()
        change(&working)
    }

    private func undoStep() {
        guard let last = undo.popLast() else { return }
        redo.append(working); working = last; dirty = true
        if let s = selected, working.element(s) == nil { selected = nil }
    }

    private func redoStep() {
        guard let next = redo.popLast() else { return }
        undo.append(working); working = next; dirty = true
    }

    // MARK: 읽기·저장

    private func keyChanged(_ newKey: String, full: CGSize, safe: SpoonLayout.Insets) {
        if !loadedOnce { saved = prefs.layouts ?? [:]; loadedOnce = true }
        guard newKey != key else { return }
        if key != nil, dirty { pendingKey = newKey; pendingGeometry = (full, safe); return }
        load(newKey, full: full, safe: safe)
    }

    @State private var pendingGeometry: (CGSize, SpoonLayout.Insets)?

    private func commitPending(save doSave: Bool) {
        guard let next = pendingKey else { return }
        if doSave, let key { store(key, working) }
        pendingKey = nil
        dirty = false
        if let g = pendingGeometry { load(next, full: g.0, safe: g.1) }
        pendingGeometry = nil
    }

    private func load(_ newKey: String, full: CGSize, safe: SpoonLayout.Insets) {
        key = newKey
        let stored = saved[newKey] ?? defaultArrangement(full: full, safe: safe)
        working = mirrors(newKey) ? stored.mirrored() : stored
        undo = []; redo = []; dirty = false; selected = nil
    }

    /// 빙수 기본 배치 (오른손 기준). 눈송이가 패드 안이면 그 자리도 요소로
    private func defaultArrangement(full: CGSize, safe: SpoonLayout.Insets) -> PadArrangement {
        let l = SpoonLayout.make(size: full, safe: safe, kind: prefs.kind, scale: prefs.scale, floatingStick: prefs.floatingStick,
                                 leftHanded: false, idiom: idiom)
        return SpoonLayout.arrangement(from: l, size: full, safe: safe, k: k, orbCenter: orbInPad ? l.betweenViewMenu : nil)
    }

    private func store(_ key: String, _ a: PadArrangement) {
        let final = mirrors(key) ? a.mirrored() : a
        saved[key] = final
        save(key, final)
        NSLog("[Spoon] 배치 저장 \(key) 요소 \(final.elements.count)")
    }

    private func saveAndClose() {
        if let key { store(key, working) }
        onClose()
    }

    private func resetToDefault() {
        guard let key else { return }
        saved[key] = nil
        save(key, nil)
        NSLog("[Spoon] 배치 지움 \(key)")
        let g = currentGeometry
        working = PadArrangement(elements: [])
        self.key = nil
        if let g { load(key, full: g.0, safe: g.1) }
    }

    /// 지금 창 크기와 안전 영역 (기본 배치로 되돌릴 때)
    private var currentGeometry: (CGSize, SpoonLayout.Insets)? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let w = scenes.first?.windows.first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first else { return nil }
        let i = w.safeAreaInsets
        return (w.bounds.size, (i.top, i.left, i.bottom, i.right))
    }

    private func exportLayouts() {
        let prefix = idiom == .pad ? "pad." : "phone."
        var l = saved.filter { $0.key.hasPrefix(prefix) }
        if let key { l[key] = mirrors(key) ? working.mirrored() : working }
        do { sharing = ShareItem(url: try SkinShelf.exportZip(id: prefs.effectiveSkin, layouts: l)) }
        catch { exportError = (error as? SkinShelf.Rejection)?.reason ?? error.localizedDescription }
    }

    // MARK: 요소 추가

    /// 지금 배치에 없는 요소들
    private var missing: [PadArrangement.Element] {
        var out: [PadArrangement.Element] = []
        func has(_ id: String) -> Bool { working.element(id) != nil }
        if !has("dpad") { out.append(.init(type: .dpad, anchor: .bottomLeft, x: 0, y: 0, radius: 62)) }
        if !has("stick.left") { out.append(.init(type: .stick, side: "left", anchor: .bottomLeft, x: 0, y: 0, radius: 48)) }
        if !has("stick.right") { out.append(.init(type: .stick, side: "right", anchor: .bottomRight, x: 0, y: 0, radius: 40, floating: false)) }
        for b in PadButton.allCases where b.onPad && !has("button." + b.name) {
            let pill = [.lb, .rb, .lt, .rt, .view, .menu].contains(b)
            var e = PadArrangement.Element(type: .button, button: b, anchor: .bottomRight, x: 0, y: 0,
                                           radius: PadArrangement.defaultRadius(.button, button: b))
            if pill { e.pill = true; e.stretch = 1.3 }
            switch (prefs.kind, b) {
            case (.simple, .lb), (.oneHand, .lb): e.label = "L"
            case (.simple, .rb), (.oneHand, .rb): e.label = "R"
            case (.simple, .view), (.oneHand, .view): e.label = "−"
            case (.simple, .menu), (.oneHand, .menu): e.label = "+"
            case (.retro, .view): e.label = "SELECT"; e.stretch = 2.7; e.radius = 11
            case (.retro, .menu): e.label = "START"; e.stretch = 2.7; e.radius = 11
            default: break
            }
            out.append(e)
        }
        if orbInPad && !has("orb") { out.append(.init(type: .orb, anchor: .bottomCenter, x: 0, y: 0, radius: 16)) }
        return out
    }

    private func addSheet(full: CGSize, safe: SpoonLayout.Insets, layout: SpoonLayout) -> some View {
        NavigationStack {
            List {
                let items = missing
                if items.isEmpty { Text("더할 수 있는 요소가 다 있어요").foregroundStyle(.secondary) }
                ForEach(items) { e in
                    Button {
                        add(e, full: full, safe: safe, layout: layout)
                        showAdd = false
                    } label: {
                        HStack {
                            Text(e.title)
                            Spacer()
                            Image(systemName: "plus.circle.fill").foregroundStyle(Palette.accent)
                        }
                    }
                }
            }
            .navigationTitle("요소 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { showAdd = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    /// 그 요소가 보통 있는 쪽(왼쪽 요소는 왼쪽 아래, 그 밖은 오른쪽 아래) 묶음 근처의 빈 자리에 둔다
    private func add(_ e: PadArrangement.Element, full: CGSize, safe: SpoonLayout.Insets, layout: SpoonLayout) {
        let leftSide: Bool = {
            switch e.type {
            case .dpad: return true
            case .stick: return !e.isRightStick
            case .orb: return false
            case .button: return [.lb, .lt, .view, .l3].contains(e.button ?? .a)
            }
        }()
        let r = CGFloat(e.radius) * k
        let hw = e.pill == true ? r * CGFloat(e.stretch ?? 1.3) : r
        let taken = working.elements.compactMap { frame($0.id, layout) }
        var spot: CGPoint?
        search: for dy in stride(from: r + 12, through: full.height * 0.85, by: 8) {
            for dx in stride(from: hw + 12, through: full.width * 0.5, by: 8) {
                let c = CGPoint(x: leftSide ? safe.left + dx : full.width - safe.right - dx, y: full.height - safe.bottom - dy)
                let mine = CGRect(x: c.x - hw - 6, y: c.y - r - 6, width: hw * 2 + 12, height: r * 2 + 12)
                if !taken.contains(where: { $0.intersects(mine) }) { spot = c; break search }
            }
        }
        let c = spot ?? CGPoint(x: full.width / 2, y: full.height / 2)
        mutate { $0.elements.append(e) }
        place(e.id, at: c, full: full, safe: safe)
        selected = e.id
        haptic.impactOccurred(intensity: 0.5)
    }
}

/// 도구 막대 자리: 위 가운데(안전 영역 아래), 고른 요소가 위쪽이면 아래 가운데
private struct PanelPlacement: ViewModifier {
    let atBottom: Bool
    let full: CGSize
    let safe: SpoonLayout.Insets
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if atBottom { Spacer(minLength: 0) }
            content.fixedSize(horizontal: false, vertical: true)
            if !atBottom { Spacer(minLength: 0) }
        }
        .padding(.top, max(safe.top, 8))
        .padding(.bottom, max(safe.bottom, 8))
        .frame(width: full.width, height: full.height)
    }
}

extension PadPrefs {
    /// 배치 하나를 넣거나(nil 이면 지워) 바꾼 설정
    func withLayout(_ key: String, _ a: PadArrangement?) -> PadPrefs {
        var p = self
        var l = p.layouts ?? [:]
        l[key] = a
        p.layouts = l.isEmpty ? nil : l
        return p
    }
}
