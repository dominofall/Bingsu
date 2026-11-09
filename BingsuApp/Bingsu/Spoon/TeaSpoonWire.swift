import Foundation

/// 워치 ↔ iPhone 메시지 형식 (두 타깃이 같이 컴파일한다. UIKit·PadButton 에 기대지 않는다).
/// 버튼 번호는 `PadButton.rawValue`(W3C standard mapping 순서) 와 같다.
enum TeaWire {
    /// 메시지 사전 키 (짧게: 무선 큐를 타는 작은 사전이라 바이트를 아낀다)
    static let seq = "s"        // Int, 워치가 보낸 일련번호 (중복·역순 버림)
    static let button = "b"     // Int, PadButton.rawValue
    static let event = "e"      // Int, TeaEvent.rawValue
    static let sentAt = "t"     // Double, 워치 시계(uptime). 답장에 그대로 실어 왕복 시간을 잰다
    static let ok = "k"         // 답장: 1 이면 받음, 0 이면 받았지만 게임이 없어 버림
    /// 앱 컨텍스트(iPhone → 워치) 키
    static let game = "game"    // String, 지금 게임 이름 ("" 이면 홈)
    static let state = "state"  // String, TeaState.rawValue
    static let enabled = "on"   // Bool, 설정 "애플워치로 조작"

    enum Event: Int {
        case tap = 0        // 누르고 바로 뗌 (iPhone 이 press 뒤 release; minPress 가 놓치지 않게 한다)
        case down = 1       // 누르고 있기 시작. 이후 0.3초마다 heartbeat, 끊기면 iPhone 이 1초 뒤 놓는다
        case up = 2         // 뗌
        case heartbeat = 3  // 누르는 중
        case ping = 4       // 왕복 시간 측정만 (입력 아님)
        case releaseAll = 5 // 워치 앱이 뒤로 가거나 화면이 바뀜 → 모두 놓기
    }

    enum State: String {
        case home       // 게임 화면 아님
        case playing    // 게임 중
        case paused     // 일시정지 화면
    }

    /// 워치 화면에 두는 버튼 (PadButton 번호). 워치는 PadButton 을 모르므로 여기 적는다
    enum Button: Int, CaseIterable {
        case a = 0, b = 1, x = 2, y = 3, view = 8, menu = 9, up = 12, down = 13, left = 14, right = 15, home = 16
        var glyph: String {
            switch self {
            case .a: return "A"; case .b: return "B"; case .x: return "X"; case .y: return "Y"
            case .view: return "⧉"; case .menu: return "≡"; case .up: return "▲"; case .down: return "▼"
            case .left: return "◀"; case .right: return "▶"; case .home: return "⌂"
            }
        }
    }

    /// 누르고 있기 하트비트 간격과, iPhone 이 끊겼다고 보는 시간
    static let heartbeatInterval: TimeInterval = 0.3
    static let holdTimeout: TimeInterval = 1.0

    static func message(seq: Int, button: Int, event: Event, sentAt: Double) -> [String: Any] {
        [Self.seq: seq, Self.button: button, Self.event: event.rawValue, Self.sentAt: sentAt]
    }
}
