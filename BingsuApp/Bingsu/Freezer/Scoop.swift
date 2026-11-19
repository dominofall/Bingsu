import Foundation

/// 한 숟갈 떠 두기: 일시정지 화면의 빠른 저장/불러오기 (빌드 49).
///
/// 실행 상태를 통째로 뜨지 않고, 게임이 원래 쓰는 저장 코드를 빙수가 불러 빙수 전용 파일 하나에 저장하고 불러온다.
/// - RPG Maker XP·VX·VX Ace(Essentials 포함): `BrassBowlEngine.scoopScript`(Ruby) 가 맵 화면에서 게임의 저장 함수를 부른다.
/// - MV·MZ: `Scoop.mvmzScript`(JS) 가 `DataManager.makeSaveContents`·`StorageManager` 로 저장하고, 불러올 때는 엔진 기본 흐름
///   (`createGameObjects`·`extractSaveContents`·`reloadMapIfUpdated`·`SceneManager.goto(Scene_Map)`·`onAfterLoad`)을 따른다.
/// 파일은 저장 폴더(`Saves/<dataPathApp>/`)에 게임 슬롯과 다른 이름으로 둔다. 확장자가 얼음틀(`IceTray`) 허용 목록 안이라
/// 세이브 파일 화면·백업·iCloud 로 그대로 넘어간다. 웹·Electron 게임은 지원하지 않는다.
enum Scoop {
    enum Op: String { case save, load }

    enum Outcome: Equatable {
        case ok
        /// 맵이 아니거나 이벤트·메시지·이동 중
        case busy
        /// 게임이 저장 금지를 켜 둠
        case disabled
        /// 빠른 저장 파일이 없음
        case none
        /// 게임의 저장 함수를 찾지 못함
        case unsupported
        case timeout
        case failed(String)
    }

    static let baseName = "Bingsu-quick"
    /// MV·MZ 저장 이름 (스킴 핸들러의 저장 이름 규칙 안: 영문·숫자·`-`)
    static let mvmzName = "bingsu-quick"
    /// 여러 칸 상태 저장 (빌드 49 추가): `Bingsu-state-NN`, MV·MZ `bingsu-state-NN`
    static let stateBase = "Bingsu-state-"
    static let mvmzStateBase = "bingsu-state-"
    /// 한 게임의 상태 저장 칸 수 상한
    static let maxStates = 30
    /// 자동 저장 칸 (빌드 49 추가): `Bingsu-auto`, MV·MZ `bingsu-auto`. 게임을 나갈 때와 일정 간격으로 덮어쓴다
    static let autoBase = "Bingsu-auto"
    static let mvmzAutoName = "bingsu-auto"
    static let autoKey = "bingsu.autoScoop"
    /// 자동 저장 켜짐 (기본 켬, 상태 저장 목록에서 끄고 켬)
    static var autoOn: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
    /// 자동 저장 간격 (디버그 BINGSU_AUTOSCOOP=초)
    static var autoEvery: TimeInterval { DevEnv["BINGSU_AUTOSCOOP"].flatMap(Double.init) ?? 300 }

    /// 빠른 저장 칸 하나 또는 상태 저장 칸(1…30)
    enum Slot: Hashable, Identifiable, Comparable {
        case quick
        case auto
        case state(Int)
        var id: String { tag }
        /// 사진·이름 파일에 쓰는 짧은 이름 ("quick", "03")
        var tag: String {
            switch self {
            case .quick: return "quick"
            case .auto: return "auto"
            case .state(let n): return String(format: "%02d", n)
            }
        }
        static func < (a: Slot, b: Slot) -> Bool { a.tag < b.tag }
    }

    static func supports(_ dish: Dish) -> Bool {
        !dish.isRemote && (dish.recipe == .mkxp || dish.recipe == .rpgMakerMV)
    }

    /// 칸 파일 이름. XP `Bingsu-quick.rxdata`·`Bingsu-state-03.rxdata`, VX `.rvdata`, VX Ace `.rvdata2`,
    /// MV `bingsu-quick.rpgsave`·`bingsu-state-03.rpgsave`, MZ `.rmmzsave`
    static func fileName(_ dish: Dish, _ slot: Slot = .quick) -> String? {
        guard let ext = fileExtension(dish) else { return nil }
        return baseName(dish, slot) + "." + ext
    }

    /// 확장자 없는 칸 이름 (MV·MZ 의 저장 이름)
    static func baseName(_ dish: Dish, _ slot: Slot) -> String {
        let mv = dish.recipe == .rpgMakerMV
        switch slot {
        case .quick: return mv ? mvmzName : baseName
        case .auto: return mv ? mvmzAutoName : autoBase
        case .state(let n): return (mv ? mvmzStateBase : stateBase) + String(format: "%02d", n)
        }
    }

    private static func fileExtension(_ dish: Dish) -> String? {
        switch dish.recipe {
        case .mkxp:
            switch BrassBowlEngine.rgss(for: dish) {
            case .xp: return "rxdata"
            case .vx: return "rvdata"
            case .vxAce: return "rvdata2"
            }
        case .rpgMakerMV:
            return dish.mvmz?.engine == .mz ? "rmmzsave" : "rpgsave"
        default:
            return nil
        }
    }

    static func url(_ dish: Dish, _ slot: Slot = .quick) -> URL? {
        guard supports(dish), let name = fileName(dish, slot) else { return nil }
        return Freezer(dish: dish).directory.appendingPathComponent(name)
    }

    /// 파일 이름 → 칸 (빠른 저장·상태 저장 파일이 아니면 nil)
    static func slot(ofName name: String) -> Slot? {
        let base = (name as NSString).deletingPathExtension
        if base == baseName || base == mvmzName { return .quick }
        if base == autoBase || base == mvmzAutoName { return .auto }
        for head in [stateBase, mvmzStateBase] where base.hasPrefix(head) {
            let rest = base.dropFirst(head.count)
            if rest.count == 2, rest.allSatisfy(\.isASCII), let n = Int(rest), (1...maxStates).contains(n) { return .state(n) }
        }
        return nil
    }

    /// 세이브 파일 화면에서 빠른 저장 파일인지
    static func isQuickName(_ name: String) -> Bool { slot(ofName: name) == .quick }

    /// 마지막 저장 시각 (파일 수정 시각)
    static func lastSaved(_ dish: Dish, _ slot: Slot = .quick) -> Date? {
        guard let u = url(dish, slot) else { return nil }
        return (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// 목록 화면의 칸 하나
    struct Entry: Identifiable, Equatable {
        let slot: Slot
        let date: Date
        var name: String?
        var id: String { slot.id }
    }

    /// 지금 저장 폴더에 있는 칸들 (빠른 저장 포함), 최근이 위
    static func entries(_ dish: Dish) -> [Entry] {
        guard supports(dish), let ext = fileExtension(dish) else { return [] }
        let dir = Freezer(dish: dish).directory
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        let names = ScoopShelf.names(dish)
        var out: [Entry] = []
        for u in items where u.pathExtension.lowercased() == ext {
            guard let slot = slot(ofName: u.lastPathComponent), u.lastPathComponent == fileName(dish, slot),
                  let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            out.append(Entry(slot: slot, date: d, name: names[slot.tag]))
        }
        return out.sorted { $0.date > $1.date }
    }

    /// 상태 저장 칸 수 (빠른 저장·자동 저장 빼고)
    static func stateCount(_ dish: Dish) -> Int {
        entries(dish).filter { if case .state = $0.slot { return true }; return false }.count
    }

    /// 새 칸 번호: 비어 있는 가장 작은 번호. 30칸이 다 찼으면 nil
    static func freeState(_ dish: Dish) -> Slot? {
        let used = Set(entries(dish).map(\.slot))
        return (1...maxStates).lazy.map(Slot.state).first { !used.contains($0) }
    }

    /// 칸 지우기 (파일·사진·이름). 일시정지 중(게임이 멈춘 채)에 부른다: 지운 이름을 save.json 에 표식으로 남겨 다른 기기에서도 지운다
    @MainActor
    static func remove(_ dish: Dish, _ slot: Slot) {
        guard let u = url(dish, slot), let name = fileName(dish, slot) else { return }
        IceTray.sync(dish, allowUnpack: false)
        try? FileManager.default.removeItem(at: u)
        ScoopShelf.forget(dish, slot)
        IceTray.commit(dish, gone: [name])
        Igloo.shared.afterPlay(dish, stillRunning: true)
    }

    /// 확인 창에 쓰는 절대 시각: 오늘이면 "오후 2:29", 아니면 "11월 16일 오후 2:29" (창을 띄운 뒤에도 값이 바뀌지 않게)
    static func clock(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened)
                                          : d.formatted(.dateTime.month().day().hour().minute())
    }

    /// 엔진 쪽 답("ok ace", "busy event", "busy disabled", "none", "unsupported", "error …")을 읽는다
    static func parse(_ text: String) -> Outcome {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "ok" || t.hasPrefix("ok ") { return .ok }
        if t == "busy disabled" { return .disabled }
        if t.hasPrefix("busy") { return .busy }
        if t == "none" { return .none }
        if t == "unsupported" { return .unsupported }
        return .failed(t)
    }

    static func message(_ o: Outcome, _ op: Op, _ slot: Slot = .quick) -> String {
        // 빌드 50: 빠른 저장·상태 저장을 "저장" 하나로 부른다
        switch o {
        case .ok: return op == .save ? "저장했어요" : "저장한 곳으로 돌아왔어요"
        case .busy:
            return op == .save ? "지금은 저장할 수 없어요. 맵에서 자유롭게 움직일 수 있을 때 해 주세요"
                               : "지금은 불러올 수 없어요. 맵에서 자유롭게 움직일 수 있을 때 해 주세요"
        case .disabled: return "이 게임이 지금은 저장을 막아 두었어요"
        case .none: return "저장한 데이터가 없어요"
        case .unsupported: return "이 게임은 일시정지 화면 저장을 지원하지 않아요"
        case .timeout: return "게임이 응답하지 않아요. 잠시 뒤 다시 해 주세요"
        case .failed: return op == .save ? "저장하지 못했어요" : "불러오지 못했어요"
        }
    }

    /// 디버그 BINGSU_SCOOP="초:일,…" — 게임을 연 뒤 그 시각에 (시뮬레이터 확인용, 불러오기 확인 창 없이)
    /// 일: `save`·`load`(빠른 저장), `save.3`·`load.3`(상태 저장 3번 칸), `new`(새 칸에 저장), `list`(상태 저장 목록 열기),
    /// `fill`(상태 저장 칸을 30개까지 빠른 저장 파일 복사로 채움 — 상한 문구 확인용)
    enum DebugStep { case run(Op, Slot), new, list, fill }

    static func debugPlan() -> [(Double, DebugStep)] {
        guard let s = DevEnv["BINGSU_SCOOP"] else { return [] }
        return s.split(separator: ",").compactMap { part in
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2, let t = Double(kv[0]) else { return nil }
            let w = kv[1].split(separator: ".")
            switch String(w[0]) {
            case "new": return (t, .new)
            case "list": return (t, .list)
            case "fill": return (t, .fill)
            default:
                guard let op = Op(rawValue: String(w[0])) else { return nil }
                let slot: Slot = w.count > 1 ? (w[1] == "auto" ? .auto : Int(w[1]).map(Slot.state) ?? .quick) : .quick
                return (t, .run(op, slot))
            }
        }
    }

    /// 디버그 `fill`: 빠른 저장 파일을 비어 있는 상태 저장 칸에 복사한다
    static func debugFill(_ dish: Dish) {
        guard let q = url(dish, .quick), FileManager.default.fileExists(atPath: q.path) else { return }
        while let slot = freeState(dish), let u = url(dish, slot) {
            guard (try? FileManager.default.copyItem(at: q, to: u)) != nil else { break }
        }
    }

    // MARK: MV·MZ

    /// `callAsyncJavaScript` 본문 (인자 `op`, `name` = 칸 이름 `bingsu-quick`·`bingsu-state-NN`). 게임 일시정지 중에 불러도 된다: 저장은 바로 끝나고,
    /// 불러오기는 파일을 읽어 확인한 뒤 빙수 장면으로 넘기고 게임이 다시 돌 때 바뀐다.
    /// 불러오는 동안 맵 장면이 새 게임 객체로 한 프레임이라도 돌지 않게, 불러오기 화면(Scene_Load)처럼 맵이 아닌 장면에서 바꾼다
    static let mvmzScript = #"""
    const NAME = /^bingsu-(quick|auto|state-[0-9][0-9])$/.test(String(name)) ? String(name) : "bingsu-quick";
    try {
      if (typeof SceneManager === "undefined" || typeof DataManager === "undefined" || typeof Scene_Map === "undefined" ||
          typeof StorageManager === "undefined" || typeof Scene_Base === "undefined") return "unsupported";
      const mz = typeof StorageManager.saveObject === "function";
      if (!StorageManager.isLocalMode()) return "unsupported";
      if (!mz && StorageManager.__bingsuQuick !== 2) {
        // MV 는 저장 번호로 파일 이름을 만든다. 빙수 이름만 따로 (게임 슬롯·global.rpgsave 목록에 넣지 않음)
        const path = StorageManager.localFilePath;
        StorageManager.localFilePath = function (id) {
          return /^bingsu-(quick|auto|state-[0-9][0-9])$/.test(String(id)) ? this.localFileDirectoryPath() + id + ".rpgsave" : path.apply(this, arguments);
        };
        StorageManager.__bingsuQuick = 2;
      }
      const sc = SceneManager._scene;
      const why = (function () {
        if (!(sc instanceof Scene_Map) || SceneManager.isSceneChanging()) return "scene";
        if (sc.isStarted ? !sc.isStarted() : SceneManager._sceneStarted === false) return "scene";
        if (sc.menuCalling) return "event";
        if ($gameMap.isEventRunning() || $gameMessage.isBusy() || $gamePlayer.isTransferring()) return "event";
        if ($gameTemp.isCommonEventReserved && $gameTemp.isCommonEventReserved()) return "event";
        if (sc.isBusy && sc.isBusy()) return "event";
        if (op === "save" && !$gameSystem.isSaveEnabled()) return "disabled";
        return "";
      })();
      if (why) return "busy " + why;
      if (op === "save") {
        // 저장 화면(Scene_Save.executeSave)과 같은 순서. 게임 슬롯 목록(globalInfo)은 건드리지 않는다
        $gameSystem.onBeforeSave();
        const contents = DataManager.makeSaveContents();
        if (mz) await StorageManager.saveObject(NAME, contents);
        else StorageManager.save(NAME, JsonEx.stringify(contents));
        if (window.__bingsuCard) window.__bingsuCard(NAME + (mz ? ".rmmzsave" : ".rpgsave"));
        return "ok " + (mz ? "mz" : "mv");
      }
      if (!StorageManager.exists(NAME)) return "none";
      const contents = mz ? await StorageManager.loadObject(NAME) : JsonEx.parse(StorageManager.load(NAME));
      if (!contents || !contents.map || !contents.player || !contents.system) return "error broken";
      if (!window.Scene_BingsuQuick) {
        const S = function () { this.initialize.apply(this, arguments); };
        S.prototype = Object.create(Scene_Base.prototype);
        S.prototype.constructor = S;
        // Scene_Load.onSavefileOk → DataManager.loadGame → onLoadSuccess 와 같은 일
        S.prototype.start = function () {
          Scene_Base.prototype.start.call(this);
          const c = window.__bingsuQuickContents;
          window.__bingsuQuickContents = null;
          if (c) {
            DataManager.createGameObjects();
            DataManager.extractSaveContents(c);
            if (DataManager.correctDataErrors) DataManager.correctDataErrors();
            SoundManager.playLoad();
            Scene_Load.prototype.reloadMapIfUpdated.call(this);
            this._bingsuLoaded = true;
          }
          SceneManager.goto(Scene_Map);
        };
        S.prototype.terminate = function () {
          Scene_Base.prototype.terminate.call(this);
          if (this._bingsuLoaded) $gameSystem.onAfterLoad();
        };
        window.Scene_BingsuQuick = S;
      }
      window.__bingsuQuickContents = contents;
      SceneManager.goto(window.Scene_BingsuQuick);
      return "ok " + (mz ? "mz" : "mv");
    } catch (e) {
      return "error " + String((e && e.message) || e).slice(0, 160);
    }
    """#
}
