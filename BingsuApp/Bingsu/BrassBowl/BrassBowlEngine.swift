import Foundation
import UIKit
import Darwin

/// 놋그릇: RPG Maker XP·VX·VX Ace 엔진(mkxp-z iOS 포크, GPLv3)을 실행 중에 불러와 돌린다.
///
/// 앱은 엔진을 링크하지 않는다. RPG Maker XP 게임을 처음 열 때 `Frameworks/BrassBowl.framework/BrassBowl` 을 dlopen 하고
/// `mkxp_*` 함수를 dlsym 으로 찾는다(만드는 법: BingsuApp/BrassBowl/README.md).
///
/// 제약(엔진): Ruby VM 은 한 프로세스에서 다시 시작할 수 없다 → 한 번 실행해 끝난 뒤에는 앱을 다시 열어야 RPG Maker XP 게임을 또 열 수 있다.
/// `mkxp_run_app` 은 게임이 끝날 때까지 메인 스레드를 잡고 그 안에서 런루프를 돌린다(SwiftUI 는 그대로 동작).
/// 메인 큐 블록 안에서 부르면 큐가 멈춰 교착하므로 `RunLoop.main.perform` 으로 부른다.
@MainActor
final class BrassBowlEngine: ObservableObject {
    static let shared = BrassBowlEngine()

    enum Availability: Equatable {
        case ready
        /// 이 빌드에 BrassBowl.framework 가 없음 (만들지 않고 빌드함)
        case missing
    }

    enum Phase: Equatable {
        case idle
        /// 엔진을 켜는 중 (첫 화면 전)
        case booting(dishID: String)
        case playing(dishID: String)
        /// 이번 프로세스에서 엔진이 끝났다. 다시 열려면 앱을 다시 시작해야 한다
        case ended(dishID: String, clean: Bool)
    }

    @Published private(set) var phase: Phase = .idle
    /// 엔진이 알린 오류 (스크립트 예외 등). 사용자가 확인을 누르면 엔진에 알린다
    @Published var errorMessage: String?
    /// 게임이 이름 입력 같은 글자 입력을 기다린다
    @Published private(set) var textInputActive = false
    /// 엔진이 알려 준 게임 화면 비율(가로/세로). 게임이 `Graphics.resize_screen` 으로 바꾸면 따라 바뀐다. 아직 모르면 nil
    @Published private(set) var gameAspect: CGFloat?

    var runningDishID: String? {
        switch phase {
        case .booting(let id), .playing(let id): return id
        default: return nil
        }
    }

    var hasEnded: Bool { if case .ended = phase { return true }; return false }

    // MARK: 프레임워크 찾기

    nonisolated static var frameworkBinary: URL? {
        let u = Bundle.main.privateFrameworksURL?.appendingPathComponent("BrassBowl.framework/BrassBowl")
        guard let u, FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    /// 실행 중에 바뀌지 않으므로 한 번만 본다 (게임칩이 자주 묻는다). 엔진과 앱 모두 iOS 26 이상
    nonisolated static let availability: Availability = frameworkBinary == nil ? .missing : .ready

    /// 엔진 리소스(공용 폰트·CA 번들)가 든 Assets.bundle
    private var assetsDir: URL? { Self.frameworkBinary?.deletingLastPathComponent().appendingPathComponent("Assets.bundle", isDirectory: true) }

    // MARK: 함수 표

    private typealias VoidFn = @convention(c) () -> Void
    private typealias IntFn = @convention(c) () -> Int32
    private typealias BoolGetFn = @convention(c) () -> Bool
    private typealias DoubleFn = @convention(c) () -> Double
    private typealias StrFn = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias Str2Fn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    private typealias KeyFn = @convention(c) (Int32, Int32) -> Void
    private typealias BoolFn = @convention(c) (Bool) -> Void
    private typealias IntSetFn = @convention(c) (Int32) -> Void
    private typealias PtrFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias CStrFn = @convention(c) () -> UnsafePointer<CChar>?
    private typealias RunFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    private typealias InsetsFn = @convention(c) (Float, Float, Float, Float) -> Void
    private typealias RegionFn = @convention(c) (Float, Float, Float, Float, Bool) -> Void
    typealias UserCb = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias MsgCb = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias ModeCb = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void
    typealias RectCb = @convention(c) (Float, Float, Float, Float, UnsafeMutableRawPointer?) -> Void
    private typealias SetUserCbFn = @convention(c) (UserCb?, UnsafeMutableRawPointer?) -> Void
    private typealias SetMsgCbFn = @convention(c) (MsgCb?, UnsafeMutableRawPointer?) -> Void
    private typealias SetModeCbFn = @convention(c) (ModeCb?, UnsafeMutableRawPointer?) -> Void
    private typealias SetRectCbFn = @convention(c) (RectCb?, UnsafeMutableRawPointer?) -> Void

    private var handle: UnsafeMutableRawPointer?
    /// 이번 프로세스에서 켠 게임 (끝나면 저장 파일을 묶어 올린다)
    private var dish: Dish?

    private func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else {
            NSLog("[BrassBowl] 함수 없음: \(name)")
            return nil
        }
        return unsafeBitCast(p, to: T.self)
    }

    /// 프레임워크 열기 (한 번만). RTLD_LOCAL: 엔진 안의 SDL·Ruby 이름이 앱 쪽과 섞이지 않게
    private func open() -> Bool {
        if handle != nil { return true }
        guard Self.availability == .ready, let bin = Self.frameworkBinary else { return false }
        guard let h = dlopen(bin.path, RTLD_NOW | RTLD_LOCAL) else {
            NSLog("[BrassBowl] dlopen 실패: \(String(cString: dlerror()))")
            return false
        }
        handle = h
        NSLog("[BrassBowl] 엔진 불러옴")
        return true
    }

    // MARK: 실행

    struct Launch {
        let dish: Dish
        /// 엔진이 쓰는 저장 폴더 (`System.data_directory`, Essentials 의 Game.rxdata 위치)
        let savesDir: URL
    }

    /// 게임 시작. 실패하면 이유를 돌려준다
    func start(_ launch: Launch) -> String? {
        guard runningDishID == nil else { return "다른 게임이 켜져 있어요. 그 게임을 끝낸 뒤 빙수를 다시 열어 주세요" }
        guard !hasEnded else { return Self.restartMessage }
        switch Self.availability {
        case .missing: return "이 빌드에는 이 게임을 여는 실행기가 없어요"
        case .ready: break
        }
        guard open() else { return "게임 실행기를 불러오지 못했어요" }
        let game = launch.dish.location
        let rgss = Self.rgss(for: launch.dish)
        let override = DishPrefsStore.shared.prefs(for: launch.dish.id).rubyOverride
        let profile = RubyProfile.detect(folder: game, rgss: rgss, override: ProcessInfo.processInfo.environment["BINGSU_RUBY"] ?? override)
        let screen = rgss == .xp ? "auto" : "544x416"
        NSLog("[BrassBowl] 시작 \(launch.dish.id) rgss=\(rgss.rawValue) ruby=\(profile.ruby) syntax=\(profile.syntax) screen=\(screen)")

        call("mkxp_resetSessionState")
        setSetting("rubyVersion", profile.ruby)
        setSetting("syntaxTransform", profile.syntax)
        // 온라인은 기본으로 켠다(이 게임 설정에서 끌 수 있음). 끄면 게임은 인터넷이 없는 PC 와 같은 길로 간다.
        // 엔진이 부팅할 때 한 번 읽으므로 바꾸면 빙수를 다시 열어야 적용된다
        setSetting("networkEnabled", DishPrefsStore.shared.prefs(for: launch.dish.id).allowOnline != false ? "1" : "0")
        setSetting("postloadScripts", "1")
        sym("mkxp_setLauncherIdentity", StrFn.self)?("bingsu")
        try? FileManager.default.createDirectory(at: launch.savesDir, withIntermediateDirectories: true)
        launch.savesDir.withUnsafeFileSystemRepresentation { sym("mkxp_setUserDataDirectory", StrFn.self)?($0) }
        // VX·VX Ace 저장 파일을 돌릴 곳 (savesScript). System.data_directory 와 같은 폴더
        setenv("BINGSU_SAVE_DIR", launch.savesDir.path, 1)
        if let assets = assetsDir {
            assets.appendingPathComponent("Fonts").withUnsafeFileSystemRepresentation { sym("mkxp_setSharedFontsDirectory", StrFn.self)?($0) }
            assets.appendingPathComponent("cacert.pem").withUnsafeFileSystemRepresentation { sym("mkxp_setCABundlePath", StrFn.self)?($0) }
        }
        // mkxp.json 을 게임 폴더에서 읽는다 (PoC 와 같음)
        game.withUnsafeFileSystemRepresentation { sym("mkxp_setManagedConfigDir", StrFn.self)?($0) }
        // 실제 컨트롤러는 빙수(LongSpoon)가 읽어 키로 넣는다 — 엔진이 또 읽으면 두 번 눌림
        sym("mkxp_setGameControllerCaptureEnabled", BoolFn.self)?(false)
        sym("mkxp_setTouchMouseEnabled", BoolFn.self)?(false)
        if ProcessInfo.processInfo.environment["BINGSU_MKXP_LOG"] == "1" {
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("brassbowl.log")
            log.withUnsafeFileSystemRepresentation { sym("mkxp_setDebugLogPath", StrFn.self)?($0) }
            NSLog("[BrassBowl] rgss=\(rgss.rawValue) ruby=\(profile.ruby) screen=\(screen)")
        }
        registerCallbacks()
        // 엔진 안 SDL 이 소리를 열 때 오디오 세션 분류를 자기 기본(무음 스위치를 따르는 soloAmbient)으로 바꾸지 않게, 설정과 같은 분류를 알려 준다
        let inSilent = BingsuApp.playInSilent(for: launch.dish.id)
        setenv("SDL_AUDIO_CATEGORY", inSilent ? "playback" : "ambient", 1)
        installOverlay(for: launch.dish, rgss: rgss)

        phase = .booting(dishID: launch.dish.id)
        dish = launch.dish
        gameAspect = nil
        game.withUnsafeFileSystemRepresentation { sym("mkxp_setGamePath", StrFn.self)?($0) }
        guard let run = sym("mkxp_run_app", RunFn.self) else { phase = .idle; return "게임 실행기가 맞지 않아요" }
        // 메인 큐 블록이 아니라 런루프 콜아웃에서 (app_bridge.h mkxp_run_app 주석)
        RunLoop.main.perform {
            let code = run(CommandLine.argc, CommandLine.unsafeArgv)
            NSLog("[BrassBowl] mkxp_run_app 끝 (\(code))")
            Task { @MainActor in BrassBowlEngine.shared.engineEnded() }
        }
        return nil
    }

    // MARK: 게임 소리 크기 (모든 게임 공통)

    /// 엔진에는 소리 크기 함수가 없어서, 게임 스크립트보다 먼저 도는 Ruby 스크립트(preloadScript)로 `Audio` 재생 함수를 감싸
    /// 크기에 배율을 곱한다. 배율은 파일로 주고 스크립트가 0.5초쯤마다 읽어, 바뀌면 지금 배경음을 같은 곡·새 크기로 다시 부른다
    /// (mkxp-z 는 같은 곡이면 처음부터 다시 틀지 않고 크기만 바꾼다)
    private static let volumeFile = FileManager.default.temporaryDirectory.appendingPathComponent("bingsu-volume.txt")
    private static let volumeScriptFile = FileManager.default.temporaryDirectory.appendingPathComponent("bingsu-volume.rb")
    private static let offlineScriptFile = FileManager.default.temporaryDirectory.appendingPathComponent("bingsu-offline.rb")

    private static let hostScriptFile = FileManager.default.temporaryDirectory.appendingPathComponent("bingsu-host.rb")
    private static let savesScriptFile = FileManager.default.temporaryDirectory.appendingPathComponent("bingsu_saves.rb")

    /// 같은 와이파이 방장 (2026-10-31 사용자 요청: 같은 와이파이면 게임 가능하게까지).
    /// 포켓몬 파티! 의 "온라인 방 만들기" 는 PC 에서 따로 켠 서버(127.0.0.1)를 쓰는데, iOS 에는 그 서버가 없다.
    /// 게임에 든 VMS 내장 서버를 이 기기에서 켜서 방장이 되게 한다. 내장 서버는 방이 0번 하나뿐이고 큰 자료 조각을 못 붙여서
    /// 그 두 가지만 채운다(방 번호는 접속 자료의 cluster_id, 조각은 게임의 BoardUdpFrag 규칙 그대로).
    /// 친구는 "온라인 방 찾기" 에 이 기기 와이파이 주소를 넣는다. 그 함수들이 없는 게임은 건드리지 않는다.
    /// Ruby 1.8 게임에도 같이 읽히므로 문법은 1.8 안에서만 쓴다(새 문법 기능은 실행 중 조건 안에서만 부른다)
    private static let hostScript = """
    # 빙수: 이 기기에서 온라인 방 열기 (BrassBowlEngine.hostScript)
    module BingsuHost
      @done = false
      def self.port
        (defined?(Board::DEFAULT_SERVER_PORT) && Board::DEFAULT_SERVER_PORT) || 12345
      end
      def self.tick
        return if @done
        return unless defined?(Board) && Board.respond_to?(:net_user_create) && Board.respond_to?(:net_create_cluster)
        return unless defined?(VMS::IntegratedServer::Server) && defined?(BoardUdpFrag) && defined?(UDPSocket)
        @done = true
        VMS::IntegratedServer::Server.send(:prepend, BingsuHostServer)
        class << Board
          alias_method :bingsu_net_user_create, :net_user_create
          def net_user_create
            cmds = [_INTL("이 기기에서 방 열기 (같은 와이파이)"), _INTL("PC 서버에 만들기"), _INTL("그만두기")]
            case board_choice(_INTL("어디에 방을 만들까요?"), cmds)
            when 0 then BingsuHost.open_here
            when 1 then bingsu_net_user_create
            end
          end
        end
      rescue StandardError
        @done = true
      end

      def self.open_here
        unless VMS::IntegratedServer.running
          VMS::IntegratedServer.start
          30.times { Graphics.update }   # 서버 스레드가 포트를 열 때까지
        end
        unless VMS::IntegratedServer.running
          pbMessage(_INTL("이 기기에서 방을 열지 못했습니다."))
          return
        end
        Board.set_server_address("127.0.0.1", port)
        Board.net_create_cluster
        if Board.net_available?
          ip = local_ip
          where = ip ? ip : _INTL("이 기기의 와이파이 IP")
          pbMessage(_INTL("같은 와이파이의 친구는 \\"온라인 방 찾기\\"에서\\n{1} 을 입력하면 돼요.", where))
          pbMessage(_INTL("방장이 빙수를 닫거나 다른 앱으로 가면\\n방이 멈춰요."))
        else
          VMS::IntegratedServer.stop
        end
      end

      # 와이파이(en*) 의 IPv4 주소. 없으면 사설 주소 하나
      def self.local_ip
        if Socket.respond_to?(:getifaddrs)
          Socket.getifaddrs.each do |i|
            a = i.addr
            next unless i.name.to_s.start_with?("en") && a && a.ipv4? && !a.ipv4_loopback?
            return a.ip_address
          end
        end
        a = Socket.ip_address_list.find { |x| x.ipv4_private? }
        a ? a.ip_address : nil
      rescue StandardError
        nil
      end
    end

    module BingsuHostServer
      # 친구가 IP 만 넣어도 되게 게임의 기본 포트(12345)로 연다
      def initialize
        super
        if @socket.is_a?(UDPSocket)
          @socket.close rescue nil
          @port = BingsuHost.port
          @socket = UDPSocket.new
          @socket.bind("0.0.0.0", @port)
        end
      end

      # 1000바이트 조각을 보낸 사람별로 모아 붙인 뒤 넘긴다
      def handle_packet(data, address, port, socket = nil)
        @bingsu_frag ||= {}
        whole = BoardUdpFrag.feed(@bingsu_frag, [address, port], data)
        return if whole.nil?
        super(whole, address, port, socket)
      end

      # 방 만들기에서 정한 방 번호로 들어가게 (원래는 늘 0번)
      def connect(address, port, data, socket = nil)
        cid = (data[VMS::PACKET_KEYS[:cluster_id]] rescue nil)
        return super unless cid.is_a?(Integer) && cid > 0
        if VMS::CHECK_GAME_AND_VERSION
          if data[VMS::PACKET_KEYS[:game_name]] != System.game_title
            send(:disconnect_wrong_game, address, port, socket)
            return
          end
          if data[VMS::PACKET_KEYS[:game_version]] != Settings::GAME_VERSION
            send(:disconnect_wrong_version, address, port, socket)
            return
          end
        end
        cluster = @clusters[cid]
        cluster = @clusters[cid] = VMS::IntegratedServer::Cluster.new(cid, self) if cluster.nil?
        max_players = (VMS::MAX_PLAYERS rescue 4)
        if cluster.player_count < max_players
          player = VMS::IntegratedServer::Player.new(data[VMS::PACKET_KEYS[:id]], address, port)
          player.socket = socket
          cluster.add_player(player)
          player.update(data)
        else
          send(:disconnect_full, address, port, socket)
        end
      end
    end

    class << Graphics
      alias_method :bingsu_host_update, :update
      def update(*a)
        BingsuHost.tick
        bingsu_host_update(*a)
      end
    end
    """

    /// 온라인을 끈 게임: 엔진은 비행기 모드처럼 접속을 ENETDOWN 으로 실패시키는데, 포켓몬 파티! 는 그 오류를 못 받아 멈춘다
    /// (2026-10-31 시뮬레이터). 이 게임은 소켓이 없는 기기용 길(Board.socket_available? 가 거짓 → "이 기기에서는 온라인 멀티를
    /// 쓸 수 없습니다")을 스스로 갖고 있으니, 플러그인이 다 올라온 뒤 그 길로 보낸다. 그 함수가 없는 게임은 건드리지 않는다
    private static let offlineScript = """
    # 빙수: 온라인을 끈 게임 (BrassBowlEngine.offlineScript)
    module BingsuOffline
      @done = false
      def self.tick
        return if @done
        return unless defined?(Board) && Board.respond_to?(:socket_available?)
        @done = true
        def Board.socket_available?; false; end
      rescue StandardError
        @done = true
      end
    end
    class << Graphics
      alias_method :bingsu_offline_update, :update
      def update(*a)
        BingsuOffline.tick
        bingsu_offline_update(*a)
      end
    end
    """
    private var volumeObserver: NSObjectProtocol?

    /// 실행할 RGSS 판: 디버그 BINGSU_RGSS → 가져올 때 적은 값 → 폴더 판별
    nonisolated static func rgss(for dish: Dish) -> RGSSVersion {
        if let env = ProcessInfo.processInfo.environment["BINGSU_RGSS"], let n = Int(env), let v = RGSSVersion(rawValue: n) { return v }
        return dish.rgss ?? RGSSProbe.version(folder: dish.location)
    }

    /// 엔진 설정 덮어쓰기(mkxp_setConfigOverlayJSON, 최상위 키 단위로 게임 mkxp.json 을 이긴다).
    /// preloadScript(소리 크기·온라인·VX 저장 위치), rgssVersion, RGSS2/3 기본 화면 544×416, MIDI 사운드폰트, RTP.
    /// 게임 mkxp.json 에 이미 있는 키(defScreenW·midiSoundFont·RTP)는 게임 값을 그대로 둔다
    private func installOverlay(for dish: Dish, rgss: RGSSVersion) {
        writeVolume()
        setenv("BINGSU_VOLUME_FILE", Self.volumeFile.path, 1)
        var overlay: [String: Any] = ["rgssVersion": rgss.rawValue]
        // 게임의 mkxp.json 을 읽는다(주석 줄 빼고). 읽을 수 없는데 preloadScript 키가 있으면 스크립트는 건드리지 않는다
        var own: [String: Any] = [:]
        var scriptsOK = true
        let config = dish.location.appendingPathComponent("mkxp.json")
        if let text = try? String(contentsOf: config, encoding: .utf8) {
            let stripped = text.split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            if let obj = (try? JSONSerialization.jsonObject(with: Data(stripped.utf8))) as? [String: Any] {
                own = obj
            } else if text.contains("preloadScript") {
                NSLog("[BrassBowl] 게임 mkxp.json 의 preloadScript 를 읽지 못해 빙수 스크립트를 넣지 않음")
                scriptsOK = false
            }
        }
        if scriptsOK, (try? Self.volumeScript.write(to: Self.volumeScriptFile, atomically: true, encoding: .utf8)) != nil {
            var scripts = own["preloadScript"] as? [String] ?? []
            scripts.append(Self.volumeScriptFile.path)
            let online = DishPrefsStore.shared.prefs(for: dish.id).allowOnline != false
            let extra = online ? (Self.hostScript, Self.hostScriptFile) : (Self.offlineScript, Self.offlineScriptFile)
            if (try? extra.0.write(to: extra.1, atomically: true, encoding: .utf8)) != nil {
                scripts.append(extra.1.path)
            }
            // VX·VX Ace: 게임 폴더에 쓰는 Save*.rvdata2 를 저장 데이터 폴더로. 엔진 preload(windows_fs.rb) 뒤에 돈다
            if rgss >= .vx, (try? Self.savesScript.write(to: Self.savesScriptFile, atomically: true, encoding: .utf8)) != nil {
                scripts.append(Self.savesScriptFile.path)
            }
            overlay["preloadScript"] = scripts
        }
        if rgss >= .vx, own["defScreenW"] == nil, own["defScreenH"] == nil {
            overlay["defScreenW"] = 544
            overlay["defScreenH"] = 416
        }
        if (own["midiSoundFont"] as? String ?? "").isEmpty, let sf = SoundFontShelf.current?.url {
            overlay["midiSoundFont"] = sf.path
        }
        if own["RTP"] == nil, let name = dish.rtp, let dir = RTPShelf.folder(named: name) {
            overlay["RTP"] = [dir.path]
        }
        NSLog("[BrassBowl] 설정 덧씌움 \(overlay.keys.sorted()) sf=\((overlay["midiSoundFont"] as? String).map { ($0 as NSString).lastPathComponent } ?? "-") rtp=\((overlay["RTP"] as? [String])?.first.map { ($0 as NSString).lastPathComponent } ?? "-")")
        if let data = try? JSONSerialization.data(withJSONObject: overlay), let json = String(data: data, encoding: .utf8) {
            sym("mkxp_setConfigOverlayJSON", StrFn.self)?(json)
        }
        if volumeObserver == nil {
            volumeObserver = NotificationCenter.default.addObserver(forName: BingsuApp.soundPrefsChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let e = BrassBowlEngine.shared
                    if e.runningDishID != nil { e.writeVolume() }
                }
            }
        }
    }

    private func writeVolume() {
        let v = BingsuApp.gameVolume
        try? String(format: "%.2f", v).write(to: Self.volumeFile, atomically: true, encoding: .utf8)
    }

    /// Ruby 1.8 문법 안에서만 쓴다 (예전 게임은 옛 Ruby 로 돈다)
    private static let volumeScript = """
    # 빙수: 게임별 소리 크기 (BrassBowlEngine.installVolumeScript)
    module BingsuVolume
      @path = ENV["BINGSU_VOLUME_FILE"]
      @scale = 1.0
      @stamp = nil
      @tick = 0
      @bgm = nil
      @bgs = nil
      class << self
        attr_accessor :bgm, :bgs
        def refresh
          return false unless @path && File.exist?(@path)
          s = File.read(@path).strip
          return false if s == @stamp
          @stamp = s
          v = s.to_f
          v = 0.0 if v < 0
          v = 1.0 if v > 1
          @scale = v
          true
        rescue StandardError
          false
        end
        def vol(v)
          (v.to_i * @scale).round
        end
        def again(args)
          a = args.dup
          a[1] = vol(a[1])
          a
        end
        def tick
          @tick += 1
          return unless @tick % 30 == 0
          return unless refresh
          Audio.bingsu_bgm_play(*again(@bgm)) if @bgm
          Audio.bingsu_bgs_play(*again(@bgs)) if @bgs
        rescue StandardError
        end
      end
    end
    BingsuVolume.refresh

    class << Audio
      alias_method :bingsu_bgm_play, :bgm_play
      alias_method :bingsu_bgs_play, :bgs_play
      alias_method :bingsu_me_play, :me_play
      alias_method :bingsu_se_play, :se_play
      alias_method :bingsu_bgm_stop, :bgm_stop
      alias_method :bingsu_bgs_stop, :bgs_stop
      alias_method :bingsu_bgm_fade, :bgm_fade
      alias_method :bingsu_bgs_fade, :bgs_fade
      def bgm_play(name, volume = 100, *rest)
        BingsuVolume.bgm = [name, volume] + rest
        bingsu_bgm_play(name, BingsuVolume.vol(volume), *rest)
      end
      def bgs_play(name, volume = 100, *rest)
        BingsuVolume.bgs = [name, volume] + rest
        bingsu_bgs_play(name, BingsuVolume.vol(volume), *rest)
      end
      def me_play(name, volume = 100, *rest)
        bingsu_me_play(name, BingsuVolume.vol(volume), *rest)
      end
      def se_play(name, volume = 80, *rest)
        bingsu_se_play(name, BingsuVolume.vol(volume), *rest)
      end
      def bgm_stop(*a)
        BingsuVolume.bgm = nil
        bingsu_bgm_stop(*a)
      end
      def bgs_stop(*a)
        BingsuVolume.bgs = nil
        bingsu_bgs_stop(*a)
      end
      def bgm_fade(*a)
        BingsuVolume.bgm = nil
        bingsu_bgm_fade(*a)
      end
      def bgs_fade(*a)
        BingsuVolume.bgs = nil
        bingsu_bgs_fade(*a)
      end
    end

    class << Graphics
      alias_method :bingsu_volume_update, :update
      def update(*a)
        BingsuVolume.tick
        bingsu_volume_update(*a)
      end
    end
    """

    /// VX·VX Ace 저장 위치 (2026-11-01 결정, docs/engines/IMPLEMENTATION-vx.md §4). 기본 스크립트는 `Save01.rvdata2`(VX `Save1.rvdata`)를
    /// 게임 폴더에 써서 게임 업데이트(폴더 교체) 때 사라지고 얼음틀·iCloud 가 못 본다. 게임이 저장 스크립트를 어떻게 고쳤든 먹도록
    /// 파일 API 를 감싸 상대 경로 `Save<숫자>.rvdata2|rvdata|rxdata` 만 저장 데이터 폴더(BINGSU_SAVE_DIR)로 돌린다.
    /// `Dir.glob("Save*.rvdata2")` 는 그 폴더에서 찾아 원래 모양(상대 이름)으로 돌려준다(게임이 이름에서 번호를 뽑는다).
    /// 엔진 windows_fs.rb 뒤에 돌아 그 감싸기(대소문자 무시) 위에 얹힌다. windows_fs 의 "예전 빌드 저장 되살리기"는 저장 데이터 폴더의
    /// 맨 이름 저장 파일을 게임 폴더로 옮겨 버리므로 이 게임에서는 끈다. RGSS2/3 에서만 넣는다. Ruby 1.8 문법 안에서만 쓴다
    private static let savesScript = """
    # 빙수: VX·VX Ace 저장 파일을 저장 데이터 폴더로 (BrassBowlEngine.savesScript)
    module BingsuSaves
      NAME = /\\A(?:\\.[\\\\\\/])?Save\\d*\\.(?:rvdata2|rvdata|rxdata)\\z/i
      GLOB = /\\A(?:\\.[\\\\\\/])?Save[^\\\\\\/]*\\.(?:rvdata2|rvdata|rxdata)\\z/i
      @dir = nil
      def self.dir
        return @dir if @dir
        d = ENV["BINGSU_SAVE_DIR"].to_s
        d = System.data_directory.to_s if d.empty? && defined?(System) && System.respond_to?(:data_directory)
        d = d.gsub(/[\\\\\\/]+\\z/, "")
        @dir = d.empty? ? nil : d
      end
      def self.map(path)
        return path unless path.is_a?(String) && dir
        s = path.strip
        return path unless s =~ NAME
        "#{dir}/#{s.sub(/\\A\\.[\\\\\\/]/, '')}"
      end
      def self.glob?(pat)
        pat.is_a?(String) && dir && pat.strip =~ GLOB ? true : false
      end
      def self.glob(pat)
        s = pat.strip
        lead = s[/\\A\\.[\\\\\\/]/] || ""
        want = s[lead.length..-1]
        names = (Dir.entries(dir) rescue [])
        names.select { |n| n =~ NAME && File.fnmatch(want, n) }.sort.map { |n| lead + n }
      end
      # 클래스(모듈)의 클래스 메서드를 감싼다. which = 돌릴 인자 번호들 (:all 이면 전부)
      def self.wrap(target, names, which = [0])
        sc = class << target; self; end
        names.each do |m|
          next unless sc.method_defined?(m) || sc.private_method_defined?(m)
          a = "_bingsu_saves_" + m.to_s.sub("?", "_p")
          next if sc.method_defined?(a) || sc.private_method_defined?(a)
          sc.send(:alias_method, a, m)
          idx = which == :all ? "(0...args.length).to_a" : which.inspect
          sc.class_eval("def #{m}(*args, &blk); #{idx}.each { |i| args[i] = BingsuSaves.map(args[i]) if i < args.length }; #{a}(*args, &blk); end")
          sc.send(:ruby2_keywords, m) if sc.respond_to?(:ruby2_keywords, true)
        end
      end
    end

    if defined?(MKXPSaveFS)
      module MKXPSaveFS
        def self.recover_legacy_save(*a); nil; end
        def self.recover_glob_matches(*a); nil; end
      end
    end

    BingsuSaves.wrap(File, [:open, :new, :exist?, :exists?, :file?, :size, :size?, :zero?, :mtime, :atime, :ctime, :stat,
                            :read, :binread, :readlines, :foreach, :write, :binwrite, :readable?, :writable?])
    BingsuSaves.wrap(File, [:delete, :unlink], :all)
    BingsuSaves.wrap(File, [:rename], [0, 1])
    BingsuSaves.wrap(FileTest, [:exist?, :exists?, :file?, :size, :size?, :zero?])
    BingsuSaves.wrap(IO, [:read, :binread, :readlines, :foreach])

    class << Dir
      alias_method :_bingsu_saves_glob, :glob
      def glob(pattern, *args, &blk)
        return _bingsu_saves_glob(pattern, *args, &blk) unless BingsuSaves.glob?(pattern)
        found = BingsuSaves.glob(pattern)
        return found unless blk
        found.each { |f| blk.call(f) }
        nil
      end
      alias_method :_bingsu_saves_brackets, :[]
      def [](*patterns)
        return _bingsu_saves_brackets(*patterns) unless patterns.length == 1 && BingsuSaves.glob?(patterns[0])
        BingsuSaves.glob(patterns[0])
      end
      ruby2_keywords :glob if respond_to?(:ruby2_keywords, true)
    end

    module Kernel
      alias_method :_bingsu_saves_load_data, :load_data
      alias_method :_bingsu_saves_save_data, :save_data
      def load_data(path, *args)
        _bingsu_saves_load_data(BingsuSaves.map(path), *args)
      end
      def save_data(obj, path, *args)
        _bingsu_saves_save_data(obj, BingsuSaves.map(path), *args)
      end
      module_function :load_data, :save_data
    end
    System.puts("[bingsu_saves] Save*.rvdata2/.rvdata -> #{BingsuSaves.dir}") if defined?(System) && System.respond_to?(:puts)
    """

    static let restartMessage = "이 게임은 한 번 끝나면 빙수를 다시 열어야 다시 할 수 있어요. 앱 전환기에서 빙수를 위로 밀어 닫은 뒤 다시 열어 주세요."

    private func engineEnded() {
        guard let id = runningDishID ?? { if case .ended(let i, _) = phase { return i }; return nil }() else { return }
        let clean = (sym("mkxp_didEngineExitCleanly", IntFn.self)?() ?? 0) != 0
        let first = !hasEnded
        phase = .ended(dishID: id, clean: clean)
        textInputActive = false
        guard first else { return }
        NSLog("[BrassBowl] 엔진 끝남 clean=\(clean)")
        // 게임이 마지막으로 쓴 Game.rxdata 를 save.json 으로 묶고 iCloud 로 올린다
        if let d = dish {
            IceTray.sync(d, allowUnpack: true)
            Igloo.shared.afterPlay(d, stillRunning: false)
        }
    }

    fileprivate func gameRectChanged(aspect a: CGFloat) {
        guard runningDishID != nil, a > 0.3, a < 4 else { return }
        if let old = gameAspect, abs(old - a) / old < 0.01 { return }
        NSLog("[BrassBowl] 게임 화면 비율 \(String(format: "%.3f", a))")
        gameAspect = a
    }

    /// 첫 프레임이 그려졌다
    fileprivate func frameRendered() {
        if case .booting(let id) = phase { phase = .playing(dishID: id) }
    }

    private func registerCallbacks() {
        sym("mkxp_setEngineTerminatedCallback", SetUserCbFn.self)?({ _ in
            Task { @MainActor in BrassBowlEngine.shared.engineEnded() }
        }, nil)
        sym("mkxp_setFrameRenderedCallback", SetUserCbFn.self)?({ _ in
            Task { @MainActor in BrassBowlEngine.shared.frameRendered() }
        }, nil)
        sym("mkxp_setErrorMessageCallback", SetMsgCbFn.self)?({ msg, _ in
            guard let msg else { return }
            let text = String(cString: msg)
            Task { @MainActor in
                NSLog("[BrassBowl] 엔진 오류: \(text)")
                BrassBowlEngine.shared.errorMessage = text
            }
        }, nil)
        sym("mkxp_setInfoMessageCallback", SetMsgCbFn.self)?({ msg, _ in
            // 정보 창(게임이 print 로 띄우는 것)은 로그만 남기고 바로 닫는다
            let text = msg.map { String(cString: $0) } ?? ""
            Task { @MainActor in
                NSLog("[BrassBowl] 엔진 알림: \(text)")
                BrassBowlEngine.shared.call("mkxp_signalInfoDismissed")
            }
        }, nil)
        sym("mkxp_setTextInputModeCallback", SetModeCbFn.self)?({ active, _ in
            Task { @MainActor in BrassBowlEngine.shared.textInputActive = active != 0 }
        }, nil)
        // 게임 그림이 그려지는 자리(점 단위). 엔진이 빙수가 준 자리 안에 비율을 지켜 넣으므로 가로/세로가 곧 게임 해상도 비율
        sym("mkxp_setGameRectChangedCallback", SetRectCbFn.self)?({ _, _, w, h, _ in
            guard w > 8, h > 8 else { return }
            let a = CGFloat(w / h)
            Task { @MainActor in BrassBowlEngine.shared.gameRectChanged(aspect: a) }
        }, nil)
    }

    func dismissError() {
        errorMessage = nil
        call("mkxp_signalErrorDismissed")
    }

    // MARK: 조작

    func key(_ scancode: Int32, down: Bool) {
        guard runningDishID != nil else { return }
        sym("mkxp_injectKeyEvent", KeyFn.self)?(scancode, down ? 1 : 0)
    }

    func pushText(_ text: String) {
        guard runningDishID != nil else { return }
        text.withCString { sym("mkxp_pushTextInput", StrFn.self)?($0) }
    }

    /// 홈으로 나가거나 앱이 뒤로 갈 때 멈춘다 (소리도 멈춤)
    func pause() { if runningDishID != nil { call("mkxp_requestPause") } }
    func resume() { if runningDishID != nil { call("mkxp_requestResume") } }

    /// 게임 종료. 엔진은 SDL_QUIT 을 받고 끝낸다 → engineEnded
    func terminate() {
        guard runningDishID != nil else { return }
        NSLog("[BrassBowl] 종료 요청")
        call("mkxp_requestTerminate")
    }

    var averageFPS: Double { runningDishID == nil ? 0 : (sym("mkxp_getAverageFPS", DoubleFn.self)?() ?? 0) }

    var details: String {
        guard handle != nil, let p = sym("mkxp_getDetails", CStrFn.self)?() else { return "" }
        return String(cString: p)
    }

    func setSafeArea(_ i: UIEdgeInsets) {
        guard handle != nil else { return }
        sym("mkxp_setSafeAreaInsets", InsetsFn.self)?(Float(i.top), Float(i.bottom), Float(i.left), Float(i.right))
    }

    /// 게임 화면을 창의 일부(0~1 비율)에만 그리게 한다. 비율은 엔진이 지킨다(가운데 맞춤)
    func setViewport(_ r: CGRect, in size: CGSize) {
        guard handle != nil, size.width > 0, size.height > 0 else { return }
        sym("mkxp_setHostViewportRegion", RegionFn.self)?(Float(r.minX / size.width), Float(r.minY / size.height),
                                                         Float(r.width / size.width), Float(r.height / size.height),
                                                         size.height > size.width)
    }

    /// 엔진이 만든 SDL 창. 빙수 창으로 그 뷰를 옮겨 붙인다(BrassBowlView)
    var gameWindow: UIWindow? {
        guard handle != nil, let p = sym("mkxp_getGameWindow", PtrFn.self)?() else { return nil }
        return Unmanaged<UIWindow>.fromOpaque(p).takeUnretainedValue()
    }

    private func call(_ name: String) { sym(name, VoidFn.self)?() }

    private func setSetting(_ key: String, _ value: String) {
        key.withCString { k in value.withCString { v in sym("mkxp_setSetting", Str2Fn.self)?(k, v) } }
    }
}

/// 게임 폴더를 보고 Ruby 버전·문법 변환을 고른다.
/// - mkxp.json 이 있거나 Ruby 3 DLL 을 들고 온 게임(Essentials 20~21 등) → Ruby 3.1 그대로("modern")
/// - VX Ace(RGSS3, 원래 Ruby 1.9.2) → 1.9, legacy
/// - 그 밖의 옛 게임(XP·VX, Ruby 1.8 문법) → 1.8, legacy
/// `override`("18"/"19"/"31", 이 게임 설정 › 고급 또는 BINGSU_RUBY)가 있으면 Ruby 만 그 값. 3.1 의 modern 문법은 원래 modern 인 게임만
struct RubyProfile: Equatable {
    let ruby: String
    let syntax: String

    static let choices = ["18", "19", "31"]

    static func detect(folder: URL, rgss: RGSSVersion = .xp, override: String? = nil) -> RubyProfile {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let modern = names.contains("mkxp.json") || names.contains { $0.lowercased().hasPrefix("x64-msvcrt-ruby3") }
        let auto: RubyProfile = modern ? RubyProfile(ruby: "31", syntax: "modern")
            : rgss == .vxAce ? RubyProfile(ruby: "19", syntax: "legacy") : RubyProfile(ruby: "18", syntax: "legacy")
        guard let o = override, choices.contains(o), o != auto.ruby else { return auto }
        return RubyProfile(ruby: o, syntax: o == "31" && modern ? "modern" : "legacy")
    }
}
