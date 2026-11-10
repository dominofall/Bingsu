import SwiftUI

/// 애플워치·iPhone 컨트롤러가 붙어 있는 동안 가상 패드를 손으로 보이거나 숨기는 작은 단추.
/// 워치 앱이 나간 것을 iPhone 이 알아채지 못할 때가 있어(2026-11-10 실기기) 사용자가 되돌릴 길이 필요했다.
/// - `.reveal` (패드 숨겨짐): 세로는 아래 가운데 글자 달린 알약(게임 아래 빈 띠), 가로는 왼쪽 아래 구석 아이콘만(옆 띠, 게임을 안 가린다).
/// - `.hide` (패드를 억지로 보이는 중): 왼쪽 위 구석 아이콘(눈송이 단추의 반대편; 세로에서 아래는 패드가 차지한다).
/// 게임 위에 겹치더라도 거슬리지 않게 나타나고 3초 뒤 25% 로 흐려진다. 흐려진 것은 그림뿐이고 누르는 영역(44pt)은 그대로라 바로 먹는다.
/// 실제 게임패드가 붙었을 때는 안 보인다 (손에 패드가 있으니 화면 패드가 필요 없다)
struct PadRevealButton: View {
    enum Mode { case reveal, hide }
    var mode: Mode = .reveal
    let action: () -> Void
    @State private var dim = false

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            switch mode {
            case .reveal where landscape:
                corner(icon: "gamecontroller", label: "가상 패드 보이기", top: false)
            case .reveal:
                VStack {
                    Spacer()
                    Button(action: action) {
                        Label("가상 패드 보이기", systemImage: "gamecontroller")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.black.opacity(0.45), in: Capsule())
                            .opacity(dim ? 0.25 : 1)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 2)
                }
            case .hide:
                corner(icon: "eye.slash", label: "가상 패드 숨기기", top: true)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: dim)
        .transition(.opacity)
        .task {
            dim = false
            try? await Task.sleep(for: .seconds(3))
            dim = true
        }
    }

    /// 왼쪽 구석의 아이콘 단추 (위 또는 아래)
    private func corner(icon: String, label: String, top: Bool) -> some View {
        VStack {
            if !top { Spacer() }
            HStack {
                Button(action: action) {
                    Image(systemName: icon)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.4), in: Circle())
                        .opacity(dim ? 0.25 : 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                Spacer()
            }
            .padding(.leading, 4)
            if top { Spacer() }
        }
    }
}
