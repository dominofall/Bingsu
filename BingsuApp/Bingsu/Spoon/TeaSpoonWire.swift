import Foundation

/// 워치 ↔ iPhone 메시지 형식 (두 타깃이 같이 컴파일한다. UIKit·PadButton 에 기대지 않는다).
/// 버튼 번호는 `PadButton.rawValue`(W3C standard mapping 순서) 와 같다.
enum TeaWire {
    /// 메시지 사전 키 (짧게: 무선 큐를 타는 작은 사전이라 바이트를 아낀다)
    static let seq = "s"        // Int, 워치가 보낸 일련번호 (중복·역순 버림)
    static let run = "r"        // Int, 워치 앱이 켜질 때마다 새로 뽑는 수. 바뀌면 iPhone 은 일련번호 기억을 지운다 (앱이 다시 켜져 0 부터 보내는 것을 중복으로 버리지 않게)
    static let button = "b"     // Int, PadButton.rawValue
    static let event = "e"      // Int, TeaEvent.rawValue
    static let sentAt = "t"     // Double, 워치 시계(uptime). 답장에 그대로 실어 왕복 시간을 잰다
    static let ok = "k"         // 답장: 1 이면 받음, 0 이면 받았지만 게임이 없어 버림
    /// 앱 컨텍스트(iPhone → 워치) 키
    static let game = "game"    // String, 지금 게임 이름 ("" 이면 홈)
    static let state = "state"  // String, TeaState.rawValue
    static let enabled = "on"   // Bool, 설정 "애플워치로 조작"
    /// 워치 → iPhone applicationContext 키: 워치 앱이 나간 시각(Double). 백그라운드로 가는 순간은 sendMessage 가 닿지 않을 수 있어 이 길로도 보낸다
    static let bye = "bye"

    enum Event: Int {
        case tap = 0        // 누르고 바로 뗌 (iPhone 이 press 뒤 release; minPress 가 놓치지 않게 한다)
        case down = 1       // 누르고 있기 시작. 이후 0.3초마다 heartbeat, 끊기면 iPhone 이 1초 뒤 놓는다
        case up = 2         // 뗌
        case heartbeat = 3  // 누르는 중
        case ping = 4       // 왕복 시간 측정만 (입력 아님)
        case releaseAll = 5 // 워치 앱이 뒤로 가거나 화면이 바뀜 → 모두 놓기
        // 큰숟가락(iPhone → iPad 컨트롤러, Spoon/TableSpoon.swift)만 쓴다. 워치는 받으면 무시
        case rumble = 6     // iPad → iPhone: 게임 진동 (strong·weak·duration·sharpness·repeats·gap)
        case context = 7    // iPad → iPhone: 게임 이름·상태·설정 (워치의 applicationContext 와 같은 내용)
        case stick = 8      // iPhone → iPad: 두 스틱 (lx ly rx ry, -1…1). 바뀔 때 + 기울인 동안 0.3초마다. 끊기면 iPad 가 1초 뒤 가운데로
        case bye = 9        // 워치 → iPhone: 워치 앱이 시계·다른 앱으로 나감(백그라운드). iPhone 은 바로 가상 패드 복귀. 손목 내림(비활성)에는 안 보냄
    }

    /// 스틱 메시지 키
    static let lx = "lx", ly = "ly", rx = "rx", ry = "ry"

    /// 진동 메시지 키 (rumble)
    static let strong = "i", weak = "w", duration = "d", sharpness = "sh", repeats = "r", gap = "g"

    /// 바이트로 (MultipeerConnectivity 는 Data 만 보낸다). 바이너리 plist: 사전 그대로, 작다
    static func encode(_ m: [String: Any]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: m, format: .binary, options: 0)
    }
    static func decode(_ d: Data) -> [String: Any]? {
        guard d.count <= 4096 else { return nil }   // 입력 메시지는 수십 바이트. 큰 것은 버린다
        return (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) as? [String: Any]
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

    static func message(seq: Int, run: Int = 0, button: Int, event: Event, sentAt: Double) -> [String: Any] {
        [Self.seq: seq, Self.run: run, Self.button: button, Self.event: event.rawValue, Self.sentAt: sentAt]
    }
}
