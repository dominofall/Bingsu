import SwiftUI

/// 키 설정 화면: 컨트롤러 버튼과 하드웨어 키보드 키를 바꾼다 (Spoon/KeyMap.swift).
/// 설정(전역, dish == nil), 이 게임 설정, 일시정지 화면(시트)에서 연다.
/// 바꾸는 법은 "버튼을 누르세요": 실제 컨트롤러 버튼·키보드 키를 눌러 잡는다 (연결된 것이 없으면 연결될 때까지 기다린다).
struct KeyMapView: View {
    let dish: Dish?
    /// 시트로 열 때(일시정지 화면): 자체 NavigationStack 과 닫기 버튼
    var asSheet = false

    @ObservedObject private var store = KeyMapStore.shared
    @ObservedObject private var prefsStore = DishPrefsStore.shared
    @ObservedObject private var capture = KeyCapture.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .controller
    /// 버튼·키를 잡은 뒤 무엇을 할지
    @State private var pending: Pending?
    /// 대상 고르기 시트
    @State private var picker: PickerRequest?
    @State private var confirmReset: Tab?
    /// 방금 바꾼 줄 (잠깐 밝게)
    @State private var flash: PadButton?

    enum Tab: Hashable { case controller, keyboard }
    enum Pending { case assignFn(PadButton), padForKey, keyForFn(PadButton) }
    struct PickerRequest: Identifiable {
        enum Source { case pad(PadButton), key(String) }
        let source: Source
        var id: String { switch source { case .pad(let b): return "pad." + b.name; case .key(let c): return "key." + c } }
    }

    private var map: KeyMap { _ = prefsStore.all; return store.effective(dish?.id) }
    private var cutlery: CutlerySet? { dish.map(CutlerySet.forDish) }

    var body: some View {
        if asSheet {
            NavigationStack {
                content
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            }
        } else {
            content
        }
    }

    private var content: some View {
        Form {
            Section {
                Picker("종류", selection: $tab) {
                    Text("컨트롤러").tag(Tab.controller)
                    Text("키보드").tag(Tab.keyboard)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let dish { scopeSection(dish) }
            let warnings = map.warnings(fns: meaningfulFns, label: tabLabel)
            if !warnings.isEmpty {
                Section {
                    ForEach(warnings, id: \.self) { w in
                        Label(w.text, systemImage: "exclamationmark.triangle.fill").font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                } header: { Text("겹치는 배치") }
            }
            switch tab {
            case .controller: controllerSections
            case .keyboard: keyboardSections
            }
        }
        .navigationTitle("키 설정")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if capture.waiting != nil || capture.received != nil { captureCard } }
        .animation(.easeOut(duration: 0.18), value: capture.waiting)
        .animation(.easeOut(duration: 0.18), value: capture.received)
        .sheet(item: $picker) { req in
            TargetPicker(request: req, fnLabel: fnLabel, current: current(req)) { t in apply(req, t) }
        }
        .confirmationDialog(confirmReset == .keyboard ? "키보드를 재설정할까요?" : "컨트롤러를 재설정할까요?", isPresented: Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } }),
                            titleVisibility: .visible) {
            Button("재설정", role: .destructive) {
                let t = confirmReset
                store.update(dishID: dish?.id) { t == .keyboard ? $0.resetKeys() : $0.resetPad() }
            }
        } message: {
            Text(confirmReset == .keyboard ? "지정한 키보드 키를 모두 지워요. 모든 키가 원래대로 게임에 가요." : "컨트롤러 버튼을 처음 배치로 되돌려요.")
        }
        .onAppear { capture.screenAppeared() }
        .onDisappear { capture.screenDisappeared() }
    }

    // MARK: 범위

    private func scopeSection(_ dish: Dish) -> some View {
        Section {
            Toggle(isOn: Binding(get: { store.usesOwn(dish.id) },
                                 set: { on in store.set(on ? store.global : nil, for: dish.id) })) {
                Text("이 게임만의 키 설정")
                Text(store.usesOwn(dish.id) ? "여기서 바꾼 키는 이 게임에만 적용돼요" : "끄면 설정 > 컨트롤러·키보드 > 키 설정의 값을 따라요")
            }
        } footer: {
            if store.usesOwn(dish.id) {
                Button("모든 게임에 적용") { store.setGlobal(map); store.set(nil, for: dish.id) }
                    .font(.footnote.weight(.semibold))
            }
        }
    }

    // MARK: 컨트롤러

    @ViewBuilder
    private var controllerSections: some View {
        Section {
            ForEach(KeyMap.remappable, id: \.self) { fn in
                Button { startPad(.assignFn(fn)) } label: {
                    HStack(spacing: 10) {
                        Text(fnLabel(fn)).foregroundStyle(.primary).lineLimit(2)
                        Spacer(minLength: 8)
                        let ps = map.physical(for: fn)
                        if ps.isEmpty {
                            Text("없음").foregroundStyle(.orange)
                        } else {
                            HStack(spacing: 4) { ForEach(ps, id: \.self) { chip($0.displayName, changed: $0 != fn) } }
                        }
                    }
                }
                .accessibilityLabel("\(fnLabel(fn)), 버튼 \(map.physical(for: fn).map(\.displayName).joined(separator: ", "))")
                .listRowBackground(flashBackground(fn))
            }
        } header: {
            Text("게임 버튼 · 누르는 컨트롤러 버튼")
        } footer: {
            Text("줄을 누른 뒤 그 일을 맡길 컨트롤러 버튼을 누르세요. 그 버튼이 하던 일은 서로 자리를 바꿔요. 홈 버튼은 늘 일시정지이고, 스틱은 그대로 이동이에요.")
        }

        let extra = KeyMap.remappable.filter { if case .pad = map.target(pad: $0) { return false }; return true }
        Section {
            ForEach(extra, id: \.self) { b in
                Button { picker = PickerRequest(source: .pad(b)) } label: {
                    HStack {
                        chip(b.displayName, changed: true)
                        Image(systemName: "arrow.right").font(.footnote).foregroundStyle(.secondary)
                        Text(map.target(pad: b).describe(label: fnLabel)).foregroundStyle(.primary)
                        Spacer()
                    }
                }
                .swipeActions { Button("되돌리기", role: .destructive) { store.update(dishID: dish?.id) { $0.setPad(b, nil) } } }
            }
            Button { startPad(.padForKey) } label: { Label("버튼에 키보드 키 붙이기", systemImage: "plus") }
        } header: {
            Text("키보드 키를 보내는 버튼")
        } footer: {
            Text("버튼이 게임 버튼 대신 키보드 키를 바로 보내요. 왼쪽으로 밀면 되돌려요.")
        }

        Section {
            Button("컨트롤러 재설정", role: .destructive) { confirmReset = .controller }
                .disabled(map.pad.isEmpty)
        }
    }

    // MARK: 키보드

    @ViewBuilder
    private var keyboardSections: some View {
        Section {
            HStack(spacing: 8) {
                profileButton("게임 기본", on: map.keys.isEmpty) { $0.resetKeys() }
                ForEach(KeyProfile.all) { p in
                    profileButton(p.title, on: map.matches(p)) { $0.applyProfile(p) }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } header: {
            Text("기본 배치 프로필")
        } footer: {
            Text("게임 기본은 게임이 원래 쓰는 키 그대로예요. 다른 배치를 누르면 아래 목록이 그 배치로 바뀌어요.")
        }

        Section {
            ForEach(KeyMap.remappable, id: \.self) { fn in
                let ks = map.keys(for: fn)
                let native = nativeKey(fn)
                Button { startKey(for: fn) } label: {
                    HStack(spacing: 10) {
                        Text(tabLabel(fn)).foregroundStyle(.primary).lineLimit(2)
                        Spacer(minLength: 8)
                        if ks.isEmpty && native == nil {
                            Text(dish == nil ? "게임 기본 키" : "지정되지 않음").font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
                        } else {
                            HStack(spacing: 4) {
                                ForEach(ks, id: \.self) { chip(KeyCatalog.label($0), changed: true) }
                                if let native { nativeChip(KeyCatalog.label(native)) }
                            }
                        }
                    }
                }
                .swipeActions {
                    if !ks.isEmpty { Button("지우기", role: .destructive) { store.update(dishID: dish?.id) { $0.clearKeys(for: fn) } } }
                }
                .accessibilityLabel("\(tabLabel(fn)), \((ks + [native].compactMap { $0 }).isEmpty ? "지정되지 않음" : (ks + [native].compactMap { $0 }).map(KeyCatalog.label).joined(separator: ", ") + " 키")")
                .listRowBackground(flashBackground(fn))
            }
        } header: {
            Text("게임 버튼 · 누르는 키보드 키")
        } footer: {
            Text("회색 키는 게임이 원래 쓰는 키예요. 줄을 누른 뒤 키를 누르면 원래 키 대신 그 키를 써요. 이름 입력처럼 글자를 쓰는 화면에서는 모든 키가 원래 글자로 들어가요. 왼쪽으로 밀면 지정한 키를 지워요.")
        }

        // 게임 버튼이 아닌 대상(다른 키·없음)으로 바꾼 키 — 예전 설정이나 다른 기기에서 온 값
        let other = map.keys.filter { if case .pad = $0.value { return false }; return true }.map(\.key)
            .sorted { (KeyCatalog.hid($0) ?? 0) < (KeyCatalog.hid($1) ?? 0) }
        if !other.isEmpty {
            Section {
                ForEach(other, id: \.self) { c in
                    Button { picker = PickerRequest(source: .key(c)) } label: {
                        HStack {
                            chip(KeyCatalog.label(c), changed: true)
                            Image(systemName: "arrow.right").font(.footnote).foregroundStyle(.secondary)
                            Text(map.target(key: c)?.describe(label: tabLabel) ?? "").foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                    .swipeActions { Button("지우기", role: .destructive) { store.update(dishID: dish?.id) { $0.setKey(c, nil) } } }
                }
            } header: { Text("그 밖의 키") }
        }

        Section {
            Button("키보드 재설정", role: .destructive) { confirmReset = .keyboard }
                .disabled(map.keys.isEmpty)
        }
    }

    // MARK: 버튼을 누르세요

    private func startPad(_ p: Pending) {
        pending = p
        capture.begin(.pad, onPad: { b in padCaptured(b) })
    }

    private func startKey(for fn: PadButton) {
        pending = .keyForFn(fn)
        capture.begin(.key, onKey: { c in
            store.update(dishID: dish?.id) { $0.assignKey(c, to: fn) }
            pending = nil
            flashRow(fn)
        })
    }

    private func flashRow(_ fn: PadButton) {
        withAnimation(.easeOut(duration: 0.15)) { flash = fn }
        DispatchQueue.main.asyncAfter(deadline: .now() + KeyCapture.flashHold) { withAnimation(.easeOut(duration: 0.4)) { if flash == fn { flash = nil } } }
    }

    private func flashBackground(_ fn: PadButton) -> Color? { flash == fn ? Palette.sky : nil }

    private func padCaptured(_ b: PadButton) {
        switch pending {
        case .assignFn(let fn)?: store.update(dishID: dish?.id) { $0.assign(pad: b, to: .pad(fn)) }; flashRow(fn)
        case .padForKey?: picker = PickerRequest(source: .pad(b))
        default: break
        }
        pending = nil
    }

    private var captureCard: some View {
        let isPad = capture.waiting == .pad || (capture.waiting == nil && pendingIsPad)
        let connected = capture.connected
        let target: PadButton? = { switch pending { case .assignFn(let f)?, .keyForFn(let f)?: return f; default: return nil } }()
        return ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { capture.cancel(); pending = nil }
            VStack(spacing: 14) {
                if let got = capture.received {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                        .symbolEffect(.bounce, value: got)
                    Text(got).font(.headline)
                } else {
                    ListeningIcon(systemName: isPad ? "gamecontroller.fill" : "keyboard.fill", live: connected)
                    Text(isPad ? "컨트롤러 버튼을 누르세요" : "키보드 키를 누르세요").font(.headline)
                    if let target {
                        Text("‘\(isPad ? fnLabel(target) : tabLabel(target))’에 쓸 \(isPad ? "버튼" : "키")").font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if connected {
                        Label("입력을 받고 있어요", systemImage: "dot.radiowaves.left.and.right")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Palette.accent)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Palette.sky, in: Capsule())
                    } else {
                        VStack(spacing: 4) {
                            Text(isPad ? "연결된 컨트롤러가 없어요" : "연결된 키보드가 없어요").font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                            Text("연결하면 바로 받아요").font(.footnote).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                    }
                    Button("취소", role: .cancel) { capture.cancel(); pending = nil }.buttonStyle(.bordered)
                }
            }
            .padding(20)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(16)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    private var pendingIsPad: Bool {
        switch pending { case .assignFn?, .padForKey?: return true; default: return false }
    }

    // MARK: 대상 고르기 결과

    private func current(_ r: PickerRequest) -> KeyTarget? {
        switch r.source {
        case .pad(let b): return map.target(pad: b)
        case .key(let c): return map.target(key: c)
        }
    }

    private func apply(_ r: PickerRequest, _ t: KeyTarget) {
        store.update(dishID: dish?.id) { m in
            switch r.source {
            case .pad(let b): m.setPad(b, t)
            case .key(let c): m.setKey(c, t)
            }
        }
    }

    // MARK: 이름

    /// 이 게임에서 뜻이 있는 패드 기능 (경고는 이것만). 게임 없이 열면 모두
    private var meaningfulFns: Set<PadButton>? {
        guard let c = cutlery else { return nil }
        if c.transport == .gamepad { return Set(KeyMap.remappable) }
        return Set(KeyMap.remappable.filter { c.keys[$0] != nil })
    }

    /// 키보드 탭에서는 게임에 보내는 키 "(C)"를 빼고 보인다 — 옆에 지정한 키보드 키와 헷갈려서 (2026-11-14 사용자)
    private func tabLabel(_ b: PadButton) -> String { fnLabel(b, withKey: tab == .controller) }

    private func fnLabel(_ b: PadButton) -> String { fnLabel(b, withKey: true) }

    /// "A · 확인 (C)" 처럼 버튼 + 이 게임에서 하는 일 + (게임에 보내는 키)
    private func fnLabel(_ b: PadButton, withKey: Bool) -> String {
        var s = b.isDpad ? "십자키 \(b.displayName)" : b.displayName
        guard let c = cutlery else { return s }
        let l = c.label(b, mode: .field)
        let k = withKey && c.transport == .keyboard ? c.keys[b].map(KeyCatalog.label) : nil
        switch (l, k) {
        case let (l?, k?): s += " · \(l) (\(k))"
        case let (l?, nil): s += " · \(l)"
        case let (nil, k?): s += " · \(k) 키"
        default: break
        }
        return s
    }

    /// 게임이 원래 받는 키 (키보드로 받는 게임만). 키를 지정했거나 그 키를 다른 일로 바꿨으면 보이지 않는다
    private func nativeKey(_ fn: PadButton) -> String? {
        guard map.keys(for: fn).isEmpty, let c = cutlery, c.transport == .keyboard, let k = c.keys[fn], KeyCatalog.isKnown(k), map.target(key: k) == nil else { return nil }
        return k
    }

    private func nativeChip(_ t: String) -> some View {
        Text(t).font(.footnote.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .accessibilityLabel("\(t), 게임 기본")
    }

    private func profileButton(_ title: String, on: Bool, _ change: @escaping (inout KeyMap) -> Void) -> some View {
        Button { store.update(dishID: dish?.id, change) } label: {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(on ? Color.white : Palette.syrup)
                .background(on ? Palette.accent : Palette.sky, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func chip(_ t: String, changed: Bool) -> some View {
        Text(t).font(.footnote.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(changed ? Color.white : Palette.syrup)
            .background(changed ? Palette.accent : Palette.sky, in: Capsule())
    }
}

/// 대상 고르기: 게임 버튼(패드) · 키보드 키 · 끄기
private struct TargetPicker: View {
    let request: KeyMapView.PickerRequest
    let fnLabel: (PadButton) -> String
    let current: KeyTarget?
    let onPick: (KeyTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var capture = KeyCapture.shared

    private var title: String {
        switch request.source {
        case .pad(let b): return "\(b.displayName) 버튼이 할 일"
        case .key(let c): return "\(KeyCatalog.label(c)) 키가 할 일"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("게임 버튼") {
                    ForEach(KeyMap.remappable, id: \.self) { fn in
                        row(fnLabel(fn), .pad(fn))
                    }
                }
                Section {
                    if case .key = request.source {
                        Button { capture.begin(.key, onKey: { c in pick(.key(c)) }) } label: {
                            Label("다른 키를 눌러서 고르기", systemImage: "keyboard")
                        }
                    }
                    KeyGrid(selected: { if case .key(let c) = current { return c }; return nil }()) { c in pick(.key(c)) }
                        .padding(.vertical, 4)
                } header: { Text("키보드 키") }
                Section {
                    row("아무것도 안 함", .off)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
            .overlay {
                if capture.waiting == .key {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { capture.cancel() }
                        VStack(spacing: 12) {
                            Image(systemName: "keyboard.fill").font(.system(size: 30)).foregroundStyle(Palette.accent)
                            Text("보낼 키를 누르세요").font(.headline)
                            Button("취소") { capture.cancel() }.buttonStyle(.bordered)
                        }
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onDisappear { if capture.waiting != nil { capture.cancel() } }
    }

    private func row(_ text: String, _ t: KeyTarget) -> some View {
        Button { pick(t) } label: {
            HStack {
                Text(text).foregroundStyle(.primary)
                Spacer()
                if current == t { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
        }
    }

    private func pick(_ t: KeyTarget) { onPick(t); dismiss() }
}

/// 키보드 키 격자 (KeyCatalog 묶음 순서)
private struct KeyGrid: View {
    let selected: String?
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(KeyCatalog.groups, id: \.0) { g in
                Text(g.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: g.0 == "숫자패드" ? 88 : 52), spacing: 6)], spacing: 6) {
                    ForEach(g.1, id: \.self) { c in
                        Button { onPick(c) } label: {
                            Text(KeyCatalog.label(c)).font(.footnote.weight(.medium)).lineLimit(1).minimumScaleFactor(0.6)
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.bordered)
                        .tint(c == selected ? Palette.accent : .gray)
                        .accessibilityLabel("\(KeyCatalog.label(c)) 키")
                    }
                }
            }
        }
    }
}

/// "입력을 받고 있어요": 아이콘 둘레로 퍼지는 고리 (연결된 것이 없으면 멈춘 아이콘)
private struct ListeningIcon: View {
    let systemName: String
    let live: Bool
    @State private var spread = false

    var body: some View {
        ZStack {
            if live {
                ForEach(0..<2) { i in
                    Circle().stroke(Palette.accent.opacity(0.5), lineWidth: 2)
                        .frame(width: 64, height: 64)
                        .scaleEffect(spread ? 1.6 : 0.9)
                        .opacity(spread ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false).delay(Double(i) * 0.7), value: spread)
                }
            }
            Circle().fill(Palette.sky).frame(width: 64, height: 64)
            Image(systemName: systemName).font(.system(size: 28)).foregroundStyle(live ? Palette.accent : .secondary)
        }
        .frame(width: 104, height: 104)
        .onAppear { spread = true }
        .accessibilityHidden(true)
    }
}
