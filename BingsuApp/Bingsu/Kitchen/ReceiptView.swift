import SwiftUI

/// 게임 정보: 길게 누르기 메뉴 › "게임 정보". 지금 깔린 게임이 어느 파일(패치)에서 왔는지 보여 준다.
/// 기록은 가져올 때 적은 `bingsu.json`(영수증)에서 읽고, 크기는 게임 폴더를 백그라운드에서 센다.
struct ReceiptView: View {
    let dish: Dish
    @Environment(\.dismiss) private var dismiss
    @State private var receipt: Receipt?
    @State private var bytes: UInt64?

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
            }
            .tint(Palette.accent)
            .navigationTitle("게임 정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task(id: dish.id) {
            let folder = dish.location
            receipt = await Task.detached(priority: .userInitiated) { Receipt.read(folder: folder) }.value
            // 큰 게임은 파일이 수만 개라 오래 걸릴 수 있다 → 메인 스레드 밖에서
            let size = await Task.detached(priority: .utility) { Delivery.folderSize(folder) }.value
            if !Task.isCancelled { bytes = size }
        }
    }

    /// 왼쪽 이름, 오른쪽 값. 값이 아직 없으면(영수증 읽는 중) 빈 칸. 긴 파일 이름은 줄을 바꿔 다 보인다
    private func item(_ k: String, _ v: String?) -> some View {
        LabeledContent(k) {
            Text(v ?? " ").multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
