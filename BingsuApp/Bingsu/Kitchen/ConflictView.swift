import SwiftUI

/// 동기화 충돌: "어느 저장 데이터로 할까요?". 게임을 열 때 이 기기와 iCloud 쪽이 둘 다 바뀌었으면 뜬다.
/// 고르지 않은 쪽은 백업에 남는다.
struct ConflictView: View {
    let conflict: IglooConflict
    /// true = 이 기기 것 유지
    let onChoose: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("이 기기와 iCloud 에 서로 다른 저장 데이터가 있어요. 이어서 할 것을 골라 주세요.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    card(title: "이 기기", side: conflict.local, systemImage: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") {
                        onChoose(true); dismiss()
                    }
                    card(title: "iCloud", side: conflict.cloud, systemImage: "icloud") {
                        onChoose(false); dismiss()
                    }
                    Text("고르지 않은 저장 데이터는 이 게임 설정 › 백업에 남겨 둬요.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .navigationTitle("어느 저장 데이터로 할까요?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("나중에") { dismiss() } } }
        }
        .tint(Palette.accent)
    }

    private func card(title: String, side: IglooSide, systemImage: String, action: @escaping () -> Void) -> some View {
        let newer = side.savedAt >= (side == conflict.local ? conflict.cloud.savedAt : conflict.local.savedAt)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage).font(.headline)
                if newer {
                    Text("더 최근").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Palette.ribbon, in: Capsule())
                }
                Spacer()
            }
            LabeledContent("기기", value: side.device)
            LabeledContent("저장 시각", value: "\(side.savedAt.formatted(date: .abbreviated, time: .shortened)) (\(Igloo.relative(side.savedAt)))")
            if let p = side.playSeconds, p >= 60 { LabeledContent("플레이 시간", value: Self.duration(p)) }
            Button(action: action) { Text("이 저장 데이터로 하기").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
        }
        .font(.subheadline)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60)시간 \(m % 60)분" : "\(m)분"
    }
}
