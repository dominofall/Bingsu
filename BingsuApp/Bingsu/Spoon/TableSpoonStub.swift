import SwiftUI

/// 빈 껍데기: iPhone↔iPad 컨트롤러(TableSpoon)는 지금 main 에 없다 (사용자 결정 2026-11-11: 편의 기능이라 나중에, 별도 브랜치로).
/// 실제 코드(TableSpoon.swift·TableSpoonLayout.swift·TableSpoonView.swift, Bonjour 키, 로컬 네트워크 문구)는 브랜치 `feature/iphone-controller` 에 있다.
/// 되살릴 때는 이 껍데기를 넣은 커밋을 main 에서 되돌린 뒤(`git revert`) 그 브랜치를 합친다 — 브랜치만 합치면 지운 파일이 돌아오지 않는다.
/// 다른 파일은 손대지 않아도 되게 이름과 모양만 맞춘다. canHost·canRemote 가 거짓이라 설정 항목·홈 단추가 안 보이고,
/// 로컬 네트워크(MultipeerConnectivity)는 전혀 쓰지 않는다
enum TableSpoon {
    static let canHost = false
    static let canRemote = false
}


final class TableSpoonLink: ObservableObject, @unchecked Sendable {
    static let shared = TableSpoonLink()
    static let enabledKey = "bingsu.tableSpoon"
    @Published private(set) var connected = false
    @Published var invite: Invite?
    var statusLabel: String { "이 빌드에 없음" }
    weak var target: TeaSpoon?
    final class Invite: Identifiable { let id = UUID(); let name = ""; func accept(_ ok: Bool) {} }
    func start() {}
    func refresh() {}
    func setContext(game: String, state: TeaWire.State) {}
    func forwardRumble(strong: Float, weak: Float, duration: TimeInterval, sharpness: Float?, repeats: Int, gap: TimeInterval) -> Bool { false }
}

struct TableSpoonView: View {
    var body: some View { EmptyView() }
}
