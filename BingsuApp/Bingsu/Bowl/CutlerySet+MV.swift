import Foundation

extension CutlerySet {
    /// RPG Maker MV·MZ — 엔진의 표준 게임패드 표(`Input.gamepadMapper`: 0 확인, 1 취소, 2 대시(shift), 3 메뉴, 4·5 페이지, 12~15 방향)가
    /// 빙수 가상 Gamepad 배치와 그대로 맞으므로 게임패드로 보낸다. 왼스틱 축 0·1 도 엔진이 방향으로 읽는다(임계 0.5).
    /// 키보드 폴백(`keys`)은 엔진 기본 키(`Input.keyMapper`): Z 확인, X 취소, Shift 대시, Esc 메뉴, Q·W 페이지, 방향키.
    static let rpgMakerMVPad = CutlerySet(
        transport: .gamepad,
        labels: [.field: [.a: "확인", .b: "취소", .x: "대시", .y: "메뉴", .lb: "이전 페이지", .rb: "다음 페이지"]],
        keys: rpgMakerMVKeys, stickKeys: [.up: "ArrowUp", .down: "ArrowDown", .left: "ArrowLeft", .right: "ArrowRight"])

    /// 같은 배치를 키보드로 보내는 판 (패드를 못 읽는 플러그인용). 디버그 `BINGSU_MV_KEYBOARD=1` 로 고른다
    static let rpgMakerMVKeyboard = CutlerySet(
        transport: .keyboard, labels: rpgMakerMVPad.labels,
        keys: rpgMakerMVKeys, stickKeys: rpgMakerMVPad.stickKeys)

    private static let rpgMakerMVKeys: [PadButton: String] = [
        .a: "KeyZ", .b: "KeyX", .x: "ShiftLeft", .y: "Escape", .lb: "KeyQ", .rb: "KeyW", .menu: "Escape",
        .up: "ArrowUp", .down: "ArrowDown", .left: "ArrowLeft", .right: "ArrowRight"]

    static var rpgMakerMV: CutlerySet {
        DevEnv["BINGSU_MV_KEYBOARD"] == "1" ? rpgMakerMVKeyboard : rpgMakerMVPad
    }
}
