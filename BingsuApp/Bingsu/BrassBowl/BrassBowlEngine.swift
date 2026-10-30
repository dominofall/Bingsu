import Foundation
import UIKit
import Darwin

/// 놋그릇: RPG Maker XP 엔진(mkxp-z iOS 포크, GPLv3)을 실행 중에 불러와 돌린다.
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
    private typealias SetUserCbFn = @convention(c) (UserCb?, UnsafeMutableRawPointer?) -> Void
    private typealias SetMsgCbFn = @convention(c) (MsgCb?, UnsafeMutableRawPointer?) -> Void
    private typealias SetModeCbFn = @convention(c) (ModeCb?, UnsafeMutableRawPointer?) -> Void

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
        guard runningDishID == nil else { return "다른 RPG Maker XP 게임이 켜져 있어요" }
        guard !hasEnded else { return Self.restartMessage }
        switch Self.availability {
        case .missing: return "이 빌드에는 RPG Maker XP 실행기가 없어요"
        case .ready: break
        }
        guard open() else { return "RPG Maker XP 실행기를 불러오지 못했어요" }
        let game = launch.dish.location
        let profile = RubyProfile.detect(folder: game)
        NSLog("[BrassBowl] 시작 \(launch.dish.id) ruby=\(profile.ruby) syntax=\(profile.syntax)")

        call("mkxp_resetSessionState")
        setSetting("rubyVersion", profile.ruby)
        setSetting("syntaxTransform", profile.syntax)
        // 온라인 기능은 아직 열지 않는다(파티! 는 Phase 3b). 끄면 게임은 오프라인 PC 와 같은 길로 간다
        setSetting("networkEnabled", "0")
        setSetting("postloadScripts", "1")
        sym("mkxp_setLauncherIdentity", StrFn.self)?("bingsu")
        try? FileManager.default.createDirectory(at: launch.savesDir, withIntermediateDirectories: true)
        launch.savesDir.withUnsafeFileSystemRepresentation { sym("mkxp_setUserDataDirectory", StrFn.self)?($0) }
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
        }
        registerCallbacks()

        phase = .booting(dishID: launch.dish.id)
        dish = launch.dish
        game.withUnsafeFileSystemRepresentation { sym("mkxp_setGamePath", StrFn.self)?($0) }
        guard let run = sym("mkxp_run_app", RunFn.self) else { phase = .idle; return "RPG Maker XP 실행기가 맞지 않아요" }
        // 메인 큐 블록이 아니라 런루프 콜아웃에서 (app_bridge.h mkxp_run_app 주석)
        RunLoop.main.perform {
            let code = run(CommandLine.argc, CommandLine.unsafeArgv)
            NSLog("[BrassBowl] mkxp_run_app 끝 (\(code))")
            Task { @MainActor in BrassBowlEngine.shared.engineEnded() }
        }
        return nil
    }

    static let restartMessage = "RPG Maker XP 게임은 한 번 끝나면 빙수를 다시 열어야 다시 할 수 있어요. 앱 전환기에서 빙수를 위로 밀어 닫은 뒤 다시 열어 주세요."

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
/// - 그 밖의 옛 RPG Maker XP 게임(RGSS1, Ruby 1.8 문법) → legacy (엔진이 Ruby 1.8 로 돌림)
struct RubyProfile {
    let ruby: String
    let syntax: String

    static func detect(folder: URL) -> RubyProfile {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let modern = names.contains("mkxp.json") || names.contains { $0.lowercased().hasPrefix("x64-msvcrt-ruby3") }
        return modern ? RubyProfile(ruby: "31", syntax: "modern") : RubyProfile(ruby: "18", syntax: "legacy")
    }
}
