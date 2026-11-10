import SwiftUI
import UIKit

/// iPhone 컨트롤러 화면 (홈 › 게임패드 단추). 가로·세로 모두(기기 방향을 따름, 2026-11-10 세로 추가), 화면 꺼짐 없음. 연결 전에는 찾은 iPad 목록, 연결되면 전체 화면 패드.
/// 패드는 게임 화면의 가상 패드와 같은 그림(`SpoonFace`)·터치(`SpoonTouchView`)를 쓰고, 눌림 변화를 `TableSpoonRemote` 로 보낸다.
struct TableSpoonView: View {
    @ObservedObject private var remote = TableSpoonRemote.shared
    /// 게임 없이 눌림 상태만 모은다 (webView·keySink 없음 → 보내는 곳 없음)
    @StateObject private var spoon = SpoonController()
    @AppStorage("tableSpoon.floatingDpad") private var floatingDpad = true
    @AppStorage("tableSpoon.scale") private var padScale = 1.0
    @AppStorage("tableSpoon.kind") private var kindRaw = TableSpoonKind.dedicated.rawValue
    @AppStorage("tableSpoon.leftHanded") private var leftHanded = false
    private var kind: TableSpoonKind { TableSpoonKind(rawValue: kindRaw) ?? .dedicated }
    @AppStorage(PadPrefs.skinKey) private var skinID: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOptions = false

    private static let hapticDpad = UIImpactFeedbackGenerator(style: .light)
    private static let hapticFace = UIImpactFeedbackGenerator(style: .medium)
    private static let hapticShoulder = UIImpactFeedbackGenerator(style: .rigid)
    private static let hapticMenu = UIImpactFeedbackGenerator(style: .soft)

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing, height: geo.size.height + insets.top + insets.bottom)
            let layout = SpoonLayout.makeController(kind: kind, size: full, safe: (insets.top, insets.leading, insets.bottom, insets.trailing),
                                                    scale: padScale, floatingDpad: floatingDpad, leftHanded: leftHanded)
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.10, green: 0.15, blue: 0.25), Color(red: 0.04, green: 0.06, blue: 0.10)],
                               startPoint: .top, endPoint: .bottom)
                if remote.connected != nil {
                    pad(layout: layout, full: full)
                } else {
                    connectList
                        .frame(width: full.width, height: full.height)
                }
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            spoon.hapticsEnabled = false
            remote.startBrowsing()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            remote.disconnect()
            remote.stopBrowsing()
        }
        .onChange(of: scenePhase) { _, p in if p != .active { remote.releaseAll() } }
        .onChange(of: remote.found) { _, f in
            if DevEnv["BINGSU_TABLESPOON"] == "1", remote.connected == nil, remote.connecting == nil, let p = f.first { remote.connect(p) }
        }
        .onChange(of: remote.canPlay) { _, ok in
            guard ok, DevEnv["BINGSU_TABLESPOON_SELFTEST"] == "1" else { return }
            Task { @MainActor in
                // A 탭 → ▶ 누르고 있기(하트비트 2번) → B 탭 → 측정 30회
                remote.tap(.a); try? await Task.sleep(for: .seconds(0.5))
                remote.down(.right); try? await Task.sleep(for: .seconds(0.8)); remote.up(.right)
                try? await Task.sleep(for: .seconds(0.5)); remote.tap(.b)
                try? await Task.sleep(for: .seconds(0.3)); remote.setStick(right: false, vector: CGVector(dx: 1, dy: 0))
                try? await Task.sleep(for: .seconds(0.7)); remote.setStick(right: false, vector: .zero)
                try? await Task.sleep(for: .seconds(0.5)); remote.measure(count: 30)
                try? await Task.sleep(for: .seconds(3))
                if let s = remote.stats { NSLog("[TableSpoon] 자가 테스트 왕복 n=\(s.count) avg=\(Int(s.avg * 1000))ms p95=\(Int(s.p95 * 1000))ms max=\(Int(s.max * 1000))ms") }
            }
        }
        .onChange(of: spoon.pressed) { old, new in
            for b in new.subtracting(old) { remote.down(b); haptic(b) }
            for b in old.subtracting(new) { remote.up(b) }
        }
        .onChange(of: spoon.leftStick.vector) { _, v in remote.setStick(right: false, vector: v) }
        .onChange(of: spoon.rightStick.vector) { _, v in remote.setStick(right: true, vector: v) }
        .onChange(of: kindRaw) { _, _ in remote.releaseAll() }
        .sheet(isPresented: $showOptions) { options }
    }

    /// 전체 화면 패드 + 가운데 상태 글 + 아래 가운데 작은 단추 둘
    @ViewBuilder private func pad(layout: SpoonLayout, full: CGSize) -> some View {
        let skin = SkinShelf.skin(for: PadPrefs(skin: skinID.flatMap { $0.isEmpty ? nil : $0 }))
        SpoonFace(layout: drawLayout(layout), opacity: 0.9, scale: padScale, skin: skin, pressed: spoon.pressed,
                  leftStick: spoon.leftStick, rightStick: spoon.rightStick)
            .opacity(remote.canPlay ? 1 : 0.45)
        SpoonTouchView(controller: spoon, layout: layout)
        // 가운데: 게임 이름 또는 안내, 그 아래 설정·끊기. 어느 배치든 가운데는 비어 있다 (−·+ 가 아래 가운데인 배치가 있어 아래쪽은 피한다)
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(remote.canPlay ? Color(red: 0.93, green: 0.42, blue: 0.33) : Color.white.opacity(0.35)).frame(width: 7, height: 7)
                Text(remote.connected?.displayName ?? "").font(.footnote.weight(.semibold))
            }
            Text(remote.statusLabel).font(.subheadline).multilineTextAlignment(.center)
            if let s = remote.stats { Text(String(format: "왕복 %.0f ms · p95 %.0f ms", s.avg * 1000, s.p95 * 1000)).font(.caption2.monospacedDigit()).opacity(0.7) }
            HStack(spacing: 26) {
                Button { showOptions = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(Color(red: 0.90, green: 0.93, blue: 0.96))
        .frame(width: full.width * (full.height > full.width ? 0.7 : 0.34))
        // 가로: 화면 가운데. 세로: 패드가 아래쪽에 모이니 그 위 빈 자리 가운데
        .position(x: full.width / 2, y: full.height > full.width ? ((layout.topEdge ?? full.height) + 40) / 2 : full.height * 0.5)
    }

    /// 떠다니는 십자키가 생겨 있으면 그 자리에 그린다
    private func drawLayout(_ l: SpoonLayout) -> SpoonLayout {
        var d = l
        if let c = spoon.dpadFloatCenter { d.dpadCenter = c }
        return d
    }

    private var connectList: some View {
        VStack(spacing: 14) {
            Text("iPad 컨트롤러").font(.title3.weight(.semibold))
            if remote.found.isEmpty {
                ProgressView().tint(.white)
                Text("iPad 에서 빙수를 열어 두세요.\n설정 › 컨트롤러 › ‘iPhone 을 컨트롤러로’가 켜져 있어야 해요.\n같은 Wi-Fi 나 블루투스 범위 안에서만 보여요.")
                    .font(.footnote).multilineTextAlignment(.center).opacity(0.75)
            } else {
                ForEach(remote.found, id: \.self) { p in
                    Button {
                        remote.connect(p)
                    } label: {
                        HStack {
                            Image(systemName: "ipad.landscape")
                            Text(p.displayName)
                            Spacer()
                            if remote.connecting == p { ProgressView().tint(.white) } else { Text("연결").font(.footnote.weight(.semibold)) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 360)
                }
                Text("iPad 화면에 뜨는 물음에서 ‘연결’을 눌러 주세요").font(.footnote).opacity(0.75)
            }
            if !remote.lastError.isEmpty { Text(remote.lastError).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
            Button("닫기") { dismiss() }.buttonStyle(.bordered).tint(.white).padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(24)
    }

    private var options: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("종류", selection: $kindRaw) {
                        ForEach(TableSpoonKind.allCases, id: \.rawValue) { k in Text(k.label).tag(k.rawValue) }
                    }
                    if kind == .dedicated {
                        Toggle(isOn: $floatingDpad) {
                            Text("떠다니는 십자키")
                            Text("왼쪽 화면 아무 데나 엄지를 대면 그 자리가 십자키 가운데가 돼요. 끄면 자리가 고정돼요")
                        }
                    } else if kind.hasStick {
                        Text("왼쪽 화면 아무 데나 엄지를 대면 그 자리에 스틱이 생겨요").font(.footnote).foregroundStyle(.secondary)
                    } else if kind == .oneHand {
                        Text("세로로 들었을 때 엄지 하나로 쓰는 배치예요. 가로로 돌리면 기본 배치로 바뀌어요").font(.footnote).foregroundStyle(.secondary)
                        Picker("쓰는 손", selection: $leftHanded) { Text("오른손").tag(false); Text("왼손").tag(true) }.pickerStyle(.segmented)
                    }
                    Text("세로로 들면 세로 배치, 가로로 들면 가로 배치예요").font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Text("크기")
                        Slider(value: $padScale, in: 0.85...1.2)
                        Text(String(format: "%.0f%%", padScale * 100)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                } header: { Text("패드") }
                Section {
                    if let s = remote.stats {
                        LabeledContent("횟수", value: "\(s.count)")
                        LabeledContent("평균", value: ms(s.avg)); LabeledContent("p50", value: ms(s.p50))
                        LabeledContent("p95", value: ms(s.p95)); LabeledContent("최대", value: ms(s.max))
                    } else {
                        Text("아직 기록 없음").foregroundStyle(.secondary)
                    }
                    Button(remote.measuring ? "측정 중…" : "100회 측정") { remote.measure() }
                        .disabled(remote.measuring || remote.connected == nil)
                } header: { Text("왕복 시간") } footer: { Text("베타 동안만 보여요. 평균·p95 를 알려 주시면 큰 도움이 돼요") }
            }
            .navigationTitle("iPad 컨트롤러")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { showOptions = false } } }
        }
    }

    private func ms(_ s: Double) -> String { String(format: "%.0f ms", s * 1000) }

    /// 묶음마다 다른 진동 (조건 2). 십자키 가벼움 · ABXY 보통 · L/R 단단함 · −+ 부드러움
    private func haptic(_ b: PadButton) {
        switch b {
        case .up, .down, .left, .right: Self.hapticDpad.impactOccurred(intensity: 0.7)
        case .a, .b, .x, .y: Self.hapticFace.impactOccurred(intensity: 0.8)
        case .lb, .rb, .lt, .rt: Self.hapticShoulder.impactOccurred(intensity: 0.8)
        default: Self.hapticMenu.impactOccurred(intensity: 0.9)
        }
    }
}
