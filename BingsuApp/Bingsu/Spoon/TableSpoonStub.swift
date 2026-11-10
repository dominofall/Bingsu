import SwiftUI

/// release/36 전용 빈 껍데기: iPhone↔iPad 컨트롤러(TableSpoon)를 이 빌드에서 뺀다 (사용자 결정 2026-11-10, 36 = 워치 기능 최적화만).
/// main 의 TableSpoon.swift·TableSpoonLayout.swift·TableSpoonView.swift 대신 이 파일 하나. 다른 파일은 손대지 않아도 되게 이름과 모양만 맞춘다.
/// canHost·canRemote 가 거짓이라 설정 항목·홈 단추가 안 보이고, 로컬 네트워크(MultipeerConnectivity)는 전혀 쓰지 않는다
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
