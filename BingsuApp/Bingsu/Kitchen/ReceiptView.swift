import SwiftUI

/// 게임 정보: 길게 누르기 메뉴 › "게임 정보". 지금 깔린 게임이 어느 파일(패치)에서 왔는지 보여 준다.
/// 기록은 가져올 때 적은 `bingsu.json`(영수증)에서 읽고, 크기는 게임 폴더를 백그라운드에서 센다.
/// 적용한 패치(Topping)는 이름·날짜를 보여 주고, 여기서 업데이트(게임 전체 또는 패치 zip)하거나 패치를 마지막 것부터 되돌린다.
struct ReceiptView: View {
    let dish: Dish
    /// "업데이트": 이 시트를 닫고 이 게임을 대상으로 zip 을 고른다 (게임 전체면 새 버전으로, 바뀐 파일만이면 패치로)
    var onUpdate: (() -> Void)? = nil
    /// 되돌리기로 게임 파일을 바꾸기 직전 (켜 둔 게임이면 닫는다)
    var onWillChange: (Dish) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var receipt: Receipt?
    @State private var bytes: UInt64?
    @State private var patches: [Topping.Record] = []
    @State private var confirmRevert = false
    @State private var reverting = false
    @State private var revertNote: String?

    private static let missing = "기록 없음"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    item("제목", dish.title)
                    item("가져온 파일", receipt.map { $0.sourceName ?? Self.missing })
                    item("가져온 날", receipt.map { $0.importedAt.map(Receipt.dateText) ?? Self.missing })
                    // 버전: 키가 없으면 "기록 없음", 빈 글자(가져올 때 몰랐음)면 줄을 숨긴다
                    if let r = receipt, r.version != "" { item("버전", r.version ?? Self.missing) }
                    item("크기", bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "계산 중이에요")
                }
                if Topping.isImported(dish) {
                    patchSection
                }
            }
            .tint(Palette.accent)
            .navigationTitle("게임 정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
            .confirmationDialog("‘\(patches.last?.name ?? "")’ 패치를 되돌릴까요?", isPresented: $confirmRevert, titleVisibility: .visible) {
                Button("패치 되돌리기", role: .destructive) { revert() }
                Button("취소", role: .cancel) {}
            } message: {
                Text("이 패치가 바꾼 파일을 원래대로 돌리고 새로 넣은 파일은 지워요. 저장 데이터는 그대로예요.")
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: dish.id) {
            let folder = dish.location
            let id = dish.id
            patches = await Task.detached(priority: .userInitiated) { Topping.records(for: id) }.value
            receipt = await Task.detached(priority: .userInitiated) { Receipt.read(folder: folder) }.value
            // 큰 게임은 파일이 수만 개라 오래 걸릴 수 있다 → 메인 스레드 밖에서
            let size = await Task.detached(priority: .utility) { Delivery.folderSize(folder) }.value
            if !Task.isCancelled { bytes = size }
        }
    }

    @ViewBuilder private var patchSection: some View {
        Section {
            if patches.isEmpty {
                Text("적용한 패치가 없어요").foregroundStyle(.secondary)
            }
            ForEach(patches.reversed()) { p in
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name).font(.body).textSelection(.enabled)
                    Text("\(Receipt.dateText(p.appliedAt)) · 바꾼 파일 \(p.replaced.count)개 · 새 파일 \(p.added.count)개\(p.complete ? "" : " · 적용 중 멈춤")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let onUpdate {
                Button { onUpdate() } label: { Label("업데이트", systemImage: "arrow.down.circle") }
                    .disabled(reverting)
            }
            if !patches.isEmpty {
                Button(role: .destructive) { confirmRevert = true } label: {
                    HStack {
                        Label("패치 되돌리기", systemImage: "arrow.uturn.backward")
                        if reverting { Spacer(); ProgressView() }
                    }
                }
                .disabled(reverting)
            }
        } header: {
            Text("패치")
        } footer: {
            if let revertNote { Text(revertNote) }
            else if patches.count > 1 { Text("되돌리기는 마지막에 적용한 패치부터 하나씩 해요.") }
        }
    }

    private func revert() {
        guard !reverting else { return }
        reverting = true
        onWillChange(dish)
        let dish = dish
        Task {
            let result: Result<Topping.Record, Error> = await Task.detached(priority: .userInitiated) {
                Result { try Topping.revertLast(dish) }
            }.value
            switch result {
            case .success(let r): revertNote = "‘\(r.name)’ 패치를 되돌렸어요."
            case .failure(let e): revertNote = "되돌리지 못했어요 · \(e.localizedDescription)"
            }
            patches = await Task.detached { Topping.records(for: dish.id) }.value
            bytes = await Task.detached(priority: .utility) { Delivery.folderSize(dish.location) }.value
            reverting = false
        }
    }

    /// 왼쪽 이름, 오른쪽 값. 값이 아직 없으면(영수증 읽는 중) 빈 칸. 긴 파일 이름은 줄을 바꿔 다 보인다
    private func item(_ k: String, _ v: String?) -> some View {
        LabeledContent(k) {
            Text(v ?? " ").multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
