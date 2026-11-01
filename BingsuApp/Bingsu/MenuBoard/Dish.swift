import Foundation

/// 메뉴판에 올라가는 게임 한 그릇.
struct Dish: Identifiable, Hashable {
    enum Recipe: String {
        case electron   // 팥빙수: Electron / 로컬 웹 (dist + assets)
        case webURL     // 과일빙수: 브라우저 웹 게임
        case mkxp       // 눈꽃빙수: RPG Maker XP·VX·VX Ace / mkxp-z (판은 Dish.rgss)
        case rpgMakerMV // 녹차빙수: NW.js
        case unknown

        var badge: String {
            switch self {
            case .electron: return "팥빙수"
            case .webURL: return "과일빙수"
            case .mkxp: return "눈꽃빙수"
            case .rpgMakerMV: return "녹차빙수"
            case .unknown: return "못 만드는 메뉴"
            }
        }

        var servable: Bool {
            switch self {
            case .electron, .webURL: return true
            case .mkxp: return BrassBowlEngine.availability == .ready
            default: return false
            }
        }

        /// 열 수 없는 이유 (게임칩 상태 줄). 열 수 있으면 nil
        var unservableNote: String? {
            guard !servable else { return nil }
            return "준비 중"
        }
    }

    let id: String
    let title: String
    let recipe: Recipe
    /// 로컬 게임은 폴더, 웹 게임은 원격 URL
    let location: URL
    /// Windows %APPDATA% 폴더 이름 → 냉동실 하위 폴더 이름. 게임 파일(mkxp.json·package.json)에서 온 값이라
    /// 만들 때 한 단계 폴더 이름으로 고친다 (`../` 로 Saves 밖에 쓰지 못하게)
    let dataPathApp: String
    /// RPG Maker 게임(.mkxp)의 RGSS 판. 가져올 때 RGSSProbe 로 정해 bingsu.json 에 적는다. 그 밖의 게임은 nil
    var rgss: RGSSVersion?
    /// 게임이 쓰는 RTP 이름(ini 의 `RTP=`, 예: RPGVXAce). 없으면 nil
    var rtp: String?
    /// RTP 를 쓰는데 게임에 기본 그림이 없다 → RTP 를 넣어야 제대로 보인다
    var needsRTP = false

    init(id: String, title: String, recipe: Recipe, location: URL, dataPathApp: String,
         rgss: RGSSVersion? = nil, rtp: String? = nil, needsRTP: Bool = false) {
        self.id = id; self.title = title; self.recipe = recipe; self.location = location
        self.dataPathApp = Self.folderName(dataPathApp, fallback: id)
        self.rgss = rgss; self.rtp = rtp; self.needsRTP = needsRTP
    }

    /// RPG Maker 게임의 판 (모르면 XP — 예전 가져오기는 XP 만 받았다)
    var rgssVersion: RGSSVersion { rgss ?? .xp }

    /// 저장 폴더로 쓸 수 있는 이름: 경로 구분자·NUL·제어 문자는 `_`, 120자까지 자르고 앞뒤 공백을 뺀 다음
    /// 앞의 점을 뺀다(순서가 거꾸로면 " .. " 가 ".." 로 남는다). 결과가 비면 fallback, 그것도 안 되면 "game"
    static func folderName(_ raw: String, fallback: String) -> String {
        var s = String(raw.unicodeScalars.map { c -> Character in
            "/\\:".unicodeScalars.contains(c) || c.properties.generalCategory == .control ? "_" : Character(c)
        })
        s = String(s.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSafeFolder(s) { return s }
        if fallback != raw { return folderName(fallback, fallback: "game") }
        return "game"
    }

    /// 한 단계 폴더 이름인가 (빈 이름·`.`·`..`·경로 구분자·앞의 점 없음)
    static func isSafeFolder(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.hasPrefix(".") && !s.contains("/") && !s.contains("\\")
            && !s.contains(":") && !s.contains("\0") && s.count <= 120
    }

    var isRemote: Bool { recipe == .webURL }

    /// 빙수가 따로 맞춰 둔 웹 게임인가. 기본 제공 카드든 사용자가 주소로 넣은 것이든 호스트로 판별한다
    /// (릴리스 빌드는 기본 카드가 없어서 사용자가 넣은 카드도 같은 패드·진동·화면 조정을 받아야 함).
    var knownWeb: KnownWeb? {
        guard isRemote, let host = location.host?.lowercased() else { return nil }
        return KnownWeb.allCases.first { host == $0.host || host.hasSuffix("." + $0.host) }
    }

    enum KnownWeb: String, CaseIterable {
        case pokerogue, pokebonk
        var host: String {
            switch self {
            case .pokerogue: return "pokerogue.net"
            case .pokebonk: return "pokebonk.com"
            }
        }
    }
}
