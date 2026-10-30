import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// 게임 가져오기 화면: 진행률(얼음이 그릇에 쌓이는 모양) → (이미 있는 게임이면 업데이트 확인) → 결과.
struct DeliveryView: View {
    @ObservedObject var delivery: Delivery
    /// 실패 화면 "이어받기"를 보일지 판단 (멈춘·끊긴 내려받기의 이어받기 데이터)
    @ObservedObject var courier: Courier = .shared
    /// 업데이트로 기존 게임 파일을 바꾸기 직전. 그 게임이 켜져 있으면 닫는다.
    var onWillUpdate: (Dish) -> Void = { _ in }
    /// 실패 화면 "주소로 다시 받기"/"이어받기": 이 시트를 닫고 내려받기 시트를 연다 (7.5)
    var onRedownload: () -> Void = {}
    let onDone: (Delivery.Result?) -> Void

    @State private var backupFirst = true
    @State private var deleteOld = true
    /// 실패 화면 "다른 파일 고르기": 이 시트 안에서 파일 선택기를 열고 바로 다시 가져온다
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Group {
                if case .confirmUpdate(let p) = delivery.stage {
                    // 세로로 다 들어가면 한 줄, 가로 화면처럼 낮으면 왼쪽 안내·오른쪽 버튼, 그래도 넘치면 스크롤
                    ViewThatFits(in: .vertical) {
                        VStack(spacing: 14) { confirmInfo(p); confirmButtons(p) }.frame(maxWidth: 420)
                        HStack(alignment: .center, spacing: 28) {
                            confirmInfo(p).frame(maxWidth: 420)
                            confirmButtons(p).frame(maxWidth: 300)
                        }
                        ScrollView {
                            VStack(spacing: 14) { confirmInfo(p); confirmButtons(p) }.frame(maxWidth: 420).frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 24) {
                        Spacer()
                        switch delivery.stage {
                        case .done(let r): resultCard(r)
                        case .failed(let msg): failure(msg)
                        default: progress
                        }
                        Spacer()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
            .navigationTitle("게임 가져오기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .done = delivery.stage {} else if case .failed = delivery.stage {} else if case .confirmUpdate = delivery.stage {} else {
                        Button("취소") { delivery.cancel(); onDone(nil) }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .background(GamePicker(isPresented: $picking) { url in if let url { delivery.start(from: url) } }.frame(width: 0, height: 0))
    }

    private var progress: some View {
        VStack(spacing: 16) {
            IceBowl(fraction: delivery.stage.fraction ?? 0, indeterminate: delivery.stage.fraction == nil)
                .frame(width: 200, height: 200)
            Text(delivery.stage.title).font(.headline)
            if let f = delivery.stage.fraction {
                Text("\(Int(f * 100))%").font(.title2.bold().monospacedDigit()).foregroundStyle(Palette.accent)
                    .contentTransition(.numericText()).animation(.easeOut(duration: 0.2), value: Int(f * 100))
            }
            Text("큰 게임은 몇 분 걸릴 수 있어요. 화면을 끄지 말아 주세요.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func resultCard(_ r: Delivery.Result) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Palette.accent)
            Text(r.updatedExisting ? "업데이트했어요" : "준비됐어요").font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                row("게임", r.dish.title)
                if r.updatedExisting {
                    row("버전", Self.versionChange(r.previousVersion, r.version))
                    row("저장 데이터", r.backedUp ? "그대로 써요 · 업데이트 전 백업을 만들었어요" : "그대로 써요")
                    if r.keptOld { row("예전 버전", "Games › \(r.dish.id)\(Delivery.oldSuffix) 폴더에 남겼어요") }
                } else if let v = r.version, !v.isEmpty { row("버전", v) }
                row("용량", ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file))
                row("저장 위치", "저장 데이터 › \(r.dish.dataPathApp)")
                row("실행", r.dish.recipe.servable ? "iPhone에서 바로 실행할 수 있어요" : "아직 실행할 수 없는 형식이에요 (준비 중)")
            }
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
            Button { onDone(r) } label: { Text("확인").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
        }
    }

    /// 7.5 "이미 있는 게임이에요 · 1.4 → 1.5"
    private func confirmInfo(_ p: Delivery.Pending) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.system(size: 40)).foregroundStyle(Palette.accent)
            Text("이미 있는 게임이에요").font(.title3.bold())
            Text("\(p.existing.title) · \(Self.versionChange(p.oldVersion, p.staged.version))")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("업데이트 전 저장 데이터 백업", isOn: $backupFirst)
                Divider()
                Toggle(isOn: $deleteOld) {
                    Text("예전 버전 파일 삭제")
                    if !deleteOld {
                        Text("Games › \(p.existing.id)\(Delivery.oldSuffix) 폴더에 남겨요. 게임 목록에는 안 보여요.")
                    }
                }
            }
            .tint(Palette.accent)
            .padding(14)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func confirmButtons(_ p: Delivery.Pending) -> some View {
        VStack(spacing: 12) {
            Text("업데이트하면 게임 파일만 바뀌고 저장 데이터·게임별 설정·표지는 그대로 써요. 따로 추가하면 게임칩이 하나 더 생기고 저장 데이터는 함께 써요.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onWillUpdate(p.existing)
                delivery.confirm(.update(p.existing, backup: backupFirst, keepOld: !deleteOld))
            } label: { Text("업데이트").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
                .keyboardShortcut(.defaultAction)
            Button { delivery.confirm(.copy) } label: { Text("따로 하나 더 추가").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
            Button("취소", role: .cancel) { delivery.cancel(); onDone(nil) }
                .padding(.top, 2)
        }
    }

    /// "1.4 → 1.5", 하나만 알면 "알 수 없음 → 1.5", 둘 다 모르면 "버전 알 수 없음"
    static func versionChange(_ old: String?, _ new: String?) -> String {
        let o = old.flatMap { $0.isEmpty ? nil : $0 }, n = new.flatMap { $0.isEmpty ? nil : $0 }
        switch (o, n) {
        case (nil, nil): return "버전 알 수 없음"
        case let (o?, n?) where o == n: return "\(n) (같은 버전)"
        default: return "\(o ?? "알 수 없음") → \(n ?? "알 수 없음")"
        }
    }

    private func failure(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("가져오지 못했어요").font(.title3.bold())
            Text(msg).multilineTextAlignment(.center).foregroundStyle(.secondary)
            // 끊긴 내려받기의 이어받기 데이터가 있으면 처음부터 받기보다 이어받기를 먼저 권한다
            if courier.canResume {
                Button { courier.resume(); onRedownload() } label: { Text("이어받기").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
            }
            Button {
                if !courier.state.isActive { courier.cancel() } // 실패 상태·남은 데이터를 치우고 주소 입력부터
                onRedownload()
            } label: { Text("주소로 다시 받기").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(courier.canResume ? Palette.accent.opacity(0.75) : Palette.accent)
            Button { picking = true } label: { Text("다른 파일 고르기").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
            Button("닫기") { onDone(nil) }
        }
        .frame(maxWidth: 420)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(v).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.subheadline)
    }
}

/// 진행률을 앱 아이콘과 같은 빙수 그림으로: 빈 파란 유리 굽잔에 얼음이 퍼센트만큼 차오르고,
/// 85% 에 시럽, 100% 에 딸기가 올라간다. 기본 게임과 같은 Phaser 장면(`Resources/IceBowl/index.html`)을
/// 투명한 웹 뷰에 띄우고 진행률만 넘긴다. 진행률을 모를 때는 얼음 높이는 그대로 두고 가루만 떨어진다.
/// 웹 뷰와 Phaser 가 뜨는 데 1초 남짓 걸려서, 그동안은 같은 자리에 빈 굽잔 그림(`IceBowl/cup.png`)을 먼저 보여 준다.
struct IceBowl: UIViewRepresentable {
    let fraction: Double
    var indeterminate = false

    func makeUIView(context: Context) -> Stage {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // 장면이 첫 화면을 그렸다는 알림만 받는다 (내용은 보지 않음)
        config.userContentController.add(context.coordinator, name: "bowlReady")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.isUserInteractionEnabled = false
        web.navigationDelegate = context.coordinator
        if let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "IceBowl") {
            // Phaser 는 기본 게임 폴더의 것을 같이 쓰므로 번들 전체 읽기를 연다 (번들 밖은 못 읽음)
            web.loadFileURL(page, allowingReadAccessTo: Bundle.main.bundleURL)
        }
        let stage = Stage(web: web)
        context.coordinator.stage = stage
        return stage
    }

    func updateUIView(_ stage: Stage, context: Context) {
        context.coordinator.latest = (fraction, indeterminate)
        context.coordinator.push(to: stage.web)
        stage.accessibilityLabel = indeterminate ? "가져오는 중" : "\(Int(fraction * 100))퍼센트"
    }

    static func dismantleUIView(_ stage: Stage, coordinator: Coordinator) {
        stage.web.configuration.userContentController.removeScriptMessageHandler(forName: "bowlReady")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 빈 굽잔 그림 위에 웹 뷰. 그림은 장면과 같은 자리·배율(64칸을 정수 배로 키워 가운데)에 놓는다
    final class Stage: UIView {
        let web: WKWebView
        private let cup = UIImageView(image: Bundle.main.url(forResource: "cup", withExtension: "png", subdirectory: "IceBowl")
            .flatMap { UIImage(contentsOfFile: $0.path) })

        init(web: WKWebView) {
            self.web = web
            super.init(frame: .zero)
            cup.layer.magnificationFilter = .nearest
            addSubview(cup)
            addSubview(web)
            isAccessibilityElement = true
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            web.frame = bounds
            let side = 64 * max(1, (min(bounds.width, bounds.height) / 64).rounded(.down))
            cup.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        }

        func sceneReady() { cup.isHidden = true }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var latest: (Double, Bool) = (0, true)
        weak var stage: Stage?
        private var loaded = false

        func push(to web: WKWebView) {
            guard loaded else { return }
            let f = latest.0.isFinite ? min(max(latest.0, 0), 1) : 0
            web.evaluateJavaScript("window.setProgress(\(f), \(latest.1))", completionHandler: nil)
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            push(to: web)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "bowlReady" { stage?.sceneReady() }
        }

        /// 번들 안 파일 말고는 열지 않는다
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
        }
    }
}
