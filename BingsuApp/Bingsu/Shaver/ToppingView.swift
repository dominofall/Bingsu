import SwiftUI

/// 패치 적용 진행 (Topping 을 백그라운드에서 부른다)
@MainActor
final class ToppingRun: ObservableObject {
    enum Stage {
        case idle
        case unpacking(Double)
        case planning
        case preview(Topping.Plan)
        case applying
        case done(Topping.Record)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .unpacking, .planning, .applying: return true
            default: return false
            }
        }
    }

    let dish: Dish
    @Published private(set) var stage: Stage = .idle
    private var cancelled = Delivery.CancelFlag()

    init(dish: Dish) { self.dish = dish }

    /// zip 고름 → 풀기 → 계획
    func start(source: URL) {
        guard !stage.isBusy else { return }
        discardPreview()
        let flag = Delivery.CancelFlag(); cancelled = flag
        stage = .unpacking(0)
        let dish = dish
        let scoped = source.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                if scoped { source.stopAccessingSecurityScopedResource() }
                Delivery.removeInboxCopy(source)
            }
            do {
                let (work, staged) = try Topping.unpack(source, progress: { f in
                    Task { @MainActor in if !flag.value, case .unpacking? = self?.stage { self?.stage = .unpacking(f) } }
                }, isCancelled: { flag.value })
                await self?.plan(work: work, staged: staged, sourceName: source.lastPathComponent, flag: flag, dish: dish)
            } catch {
                NSLog("[Topping] 풀기 실패: \(error.localizedDescription)")
                await MainActor.run { if !flag.value { self?.stage = .failed(error.localizedDescription) } }
            }
        }
    }

    /// 가져오기(Delivery)가 이미 풀어 둔 패치 zip 으로 시작
    func start(offer: Delivery.PatchOffer) {
        guard !stage.isBusy else { return }
        let flag = Delivery.CancelFlag(); cancelled = flag
        stage = .planning
        let dish = dish
        Task { await plan(work: offer.work, staged: offer.staged, sourceName: offer.sourceName, flag: flag, dish: dish) }
    }

    private func plan(work: URL, staged: URL, sourceName: String, flag: Delivery.CancelFlag, dish: Dish) async {
        stage = .planning
        NSLog("[Topping] \(dish.id) 맞춰 보는 중: \(sourceName)")
        do {
            let p = try await Task.detached(priority: .userInitiated) {
                try Topping.plan(work: work, staged: staged, dish: dish, sourceName: sourceName)
            }.value
            if flag.value { try? FileManager.default.removeItem(at: work); return }
            NSLog("[Topping] \(dish.id) 계획 ‘\(p.name)’ base=\(p.base.isEmpty ? "." : p.base) 바꿈 \(p.replacedCount) · 추가 \(p.addedCount) · 건너뜀 \(p.skipped.count)")
            stage = .preview(p)
            if DevEnv["BINGSU_PATCH_APPLY"] == "1" { apply() }   // 개발용: 미리 보기 없이 바로
        } catch {
            try? FileManager.default.removeItem(at: work)
            NSLog("[Topping] \(dish.id) 계획 실패: \(error.localizedDescription)")
            if !flag.value { stage = .failed(error.localizedDescription) }
        }
    }

    func apply() {
        guard case .preview(let p) = stage else { return }
        stage = .applying
        Task {
            do {
                let r = try await Task.detached(priority: .userInitiated) { try Topping.apply(p) }.value
                stage = .done(r)
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    /// 취소: 풀어 둔 임시 폴더만 지운다. 게임은 그대로
    func cancel() {
        if case .applying = stage { return }
        NSLog("[Topping] 취소")   // 이름 바꾸기 몇 번이라 금방 끝난다. 끝까지 둔다
        cancelled.set(true)
        discardPreview()
        stage = .idle
    }

    private func discardPreview() {
        if case .preview(let p) = stage { try? FileManager.default.removeItem(at: p.work) }
    }
}

/// 패치 적용 화면: 고르기 → 미리 보기(덮어쓸 파일 목록) → 적용 → 결과.
/// 게임칩 길게 누르기·게임 정보 › "업데이트"로 고른 zip 이 바뀐 파일만 든 패치였을 때, 패치만 든 zip 을 가져오다 게임을 고른 경우에 뜬다.
/// (zip 을 먼저 고르는 첫 화면 `intro` 는 개발용 BINGSU_PATCH 에서만 쓴다)
struct ToppingView: View {
    @StateObject private var run: ToppingRun
    /// 시작: 고를 zip(개발용)·Delivery 가 풀어 둔 것. 둘 다 없으면 파일 고르기부터
    private let initialSource: URL?
    private let offer: Delivery.PatchOffer?
    /// 게임 파일을 바꾸기 직전 (켜 둔 게임이면 닫는다)
    var onWillChange: (Dish) -> Void = { _ in }
    /// "주소로 zip 내려받기": 이 시트를 닫고 내려받기 시트를 연다 (받은 zip 은 가져오기가 패치로 알아보고 게임을 묻는다)
    var onDownload: () -> Void = {}
    let onDone: () -> Void

    @State private var picking = false
    @State private var started = false

    init(dish: Dish, source: URL? = nil, offer: Delivery.PatchOffer? = nil,
         onWillChange: @escaping (Dish) -> Void = { _ in }, onDownload: @escaping () -> Void = {}, onDone: @escaping () -> Void) {
        _run = StateObject(wrappedValue: ToppingRun(dish: dish))
        initialSource = source
        self.offer = offer
        self.onWillChange = onWillChange
        self.onDownload = onDownload
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    switch run.stage {
                    case .idle: intro
                    case .unpacking(let f): working("패치 푸는 중", fraction: f)
                    case .planning: working("게임 파일과 맞춰 보는 중", fraction: nil)
                    case .preview(let p): preview(p)
                    case .applying: working("패치 적용 중", fraction: nil)
                    case .done(let r): done(r)
                    case .failed(let msg): failure(msg)
                    }
                }
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .background(Palette.background)
            .navigationTitle("업데이트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !run.stage.isBusy, !isDone { Button("취소") { run.cancel(); onDone() } }
                }
            }
        }
        .interactiveDismissDisabled(run.stage.isBusy)
        .background(GamePicker(isPresented: $picking) { url in
            if let url { run.start(source: url) }
        }.frame(width: 0, height: 0))
        .task {
            guard !started else { return }
            started = true
            if let offer { run.start(offer: offer) } else if let initialSource { run.start(source: initialSource) }
        }
        // 사라질 때 취소하지 않는다: iPad 에서 가져오기 시트가 닫히며 이 시트를 올릴 때 한 번 사라졌다 다시 붙어
        // 풀어 둔 패치를 지워 버린다. 남은 임시 폴더는 다음 가져오기(sweepStaleWork)가 치운다
    }

    private var isDone: Bool { if case .done = run.stage { return true }; return false }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 40)).foregroundStyle(Palette.accent)
            Text(run.dish.title).font(.title3.bold()).multilineTextAlignment(.center)
            Text("한글 패치처럼 바뀐 파일만 든 zip 을 이 게임 파일 위에 덮어써요. 덮어쓰기 전 원본은 따로 보관해서 게임 정보 › 패치 되돌리기로 언제든 돌아갈 수 있어요. 저장 데이터는 건드리지 않아요.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { picking = true } label: { Text("zip 파일 고르기").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
                .keyboardShortcut(.defaultAction)
            Button { onDownload() } label: { Text("주소로 zip 내려받기").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
        }
    }

    private func working(_ title: String, fraction: Double?) -> some View {
        VStack(spacing: 14) {
            if let fraction {
                ProgressView(value: fraction).tint(Palette.accent)
                Text("\(Int(fraction * 100))%").font(.title3.bold().monospacedDigit()).foregroundStyle(Palette.accent)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(title).font(.headline)
        }
        .padding(.top, 40)
    }

    private func preview(_ p: Topping.Plan) -> some View {
        VStack(spacing: 14) {
            Text("이 패치를 적용할까요?").font(.title3.bold())
            Text("게임 전체가 아니라 바뀐 파일만 든 zip 이라, 이 게임 파일 위에 덮어써요.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // 이 게임용이 아닌 것 같거나 시작되지 않을 것 같은 패치: 막지 않고 알린다 (원본 보관·되돌리기가 있다)
            ForEach(p.warnings, id: \.self) { w in warning(w) }
            VStack(alignment: .leading, spacing: 6) {
                row("게임", p.dish.title)
                row("패치", p.name)
                if p.sourceName != p.name { row("파일", Receipt.clean(p.sourceName, limit: Receipt.maxTextLength) ?? "") }
                row("바꿀 파일", "\(p.replacedCount)개")
                row("새 파일", "\(p.addedCount)개")
                row("크기", ByteCountFormatter.string(fromByteCount: Int64(p.bytes), countStyle: .file))
                if !p.skipped.isEmpty { row("건너뜀", "\(p.skipped.count)개 · 저장 파일 등은 덮어쓰지 않아요") }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
            ForEach(p.notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fileList(p)
            Text("덮어쓰기 전 원본은 따로 보관해요. 저장 데이터는 그대로예요.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onWillChange(p.dish)
                run.apply()
            } label: { Text("적용").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
                .keyboardShortcut(.defaultAction)
            Button("취소", role: .cancel) { run.cancel(); onDone() }
        }
    }

    /// "제목 · 이유" 를 두 줄로
    private func warning(_ w: String) -> some View {
        let parts = w.components(separatedBy: " · ")
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(parts[0]).font(.subheadline.bold())
                if parts.count > 1 { Text(parts.dropFirst().joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
                Text("그래도 적용할 수 있고, 게임 정보 › 패치 되돌리기로 원래대로 돌릴 수 있어요.").font(.footnote).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    /// 덮어쓸 파일·새 파일 목록 (펼쳐 보기)
    private func fileList(_ p: Topping.Plan) -> some View {
        let shown = 300
        return DisclosureGroup {
            // 목록이 길어도 아래 "적용" 버튼이 멀어지지 않게 높이를 묶고 안에서 스크롤
            ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(p.items.prefix(shown), id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.replaces ? "바꿈" : "새로")
                            .font(.caption2.bold())
                            .foregroundStyle(item.replaces ? Color.orange : Palette.accent)
                            .frame(width: 30, alignment: .leading)
                        Text(item.target).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                    }
                }
                if p.items.count > shown {
                    Text("외 \(p.items.count - shown)개").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        } label: {
            Text("바뀌는 파일 보기").font(.subheadline)
        }
        .tint(Palette.accent)
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func done(_ r: Topping.Record) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Palette.accent)
            Text("패치를 적용했어요").font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                row("게임", run.dish.title)
                row("패치", r.name)
                row("바꾼 파일", "\(r.replaced.count)개")
                row("새 파일", "\(r.added.count)개")
                row("되돌리기", "게임을 길게 눌러 게임 정보 › 패치 되돌리기")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
            if run.dish.recipe == .mkxp {
                Text("이미 켜 둔 RPG Maker 게임이었다면 빙수를 다시 열어야 바뀐 게임으로 시작해요.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { onDone() } label: { Text("확인").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
        }
    }

    private func failure(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("패치를 적용하지 못했어요").font(.title3.bold())
            Text(msg).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("게임 파일은 그대로예요.").font(.footnote).foregroundStyle(.secondary)
            Button { picking = true } label: { Text("다른 파일 고르기").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
            Button("닫기") { onDone() }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(v).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.subheadline)
    }
}
