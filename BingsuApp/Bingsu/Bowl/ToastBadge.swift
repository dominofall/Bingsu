import SwiftUI

/// 게임 화면 위 짧은 알림 (빌드 49): 진한 배경 캡슐. 성공은 체크, 실패·거절은 느낌표, 안내는 아이콘 없음.
/// 게임 화면(BrassBowl·Bowl) 둘 다 쓴다
enum ToastTone { case info, ok, fail }

struct ToastBadge: View {
    let text: String
    var tone: ToastTone = .info

    var body: some View {
        HStack(spacing: 8) {
            switch tone {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            case .fail: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
            case .info: EmptyView()
            }
            Text(text).foregroundStyle(.white).multilineTextAlignment(.leading)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel((tone == .ok ? "완료, " : tone == .fail ? "안 됨, " : "") + text)
    }
}
