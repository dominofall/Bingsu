import SwiftUI
import GameController

/// 컨트롤러·키보드 화면: 연결된 기기, 키 설정, 애플워치·iPhone 컨트롤러, 패드 연결 안내를 한곳에 (2026-11-14 사용자 결정: 흩어져 있던 것을 하나로).
/// 설정(전역, dish == nil), 이 게임 설정, 일시정지 화면(시트)에서 연다. 진동은 폰과 같이 쓰는 값이라 설정 › 소리·진동에 둔다.
struct InputView: View {
    let dish: Dish?
    /// 시트로 열 때(일시정지 화면): 자체 NavigationStack 과 닫기 버튼
    var asSheet = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = KeyMapStore.shared
    @ObservedObject private var prefsStore = DishPrefsStore.shared
    @ObservedObject private var capture = KeyCapture.shared
    /// 지금 연결된 실제 컨트롤러 제품명 (식별자 없이)
    @State private var controllers = LongSpoon.connectedNames()
    @State private var keyboard = KeyCapture.keyboardConnected
    /// 애플워치 컨트롤러 (Spoon/TeaSpoon.swift). iPhone 에서만 보인다
    @ObservedObject private var watch = TeaSpoonLink.shared
    @AppStorage(TeaSpoonLink.enabledKey) private var watchEnabled = true
    /// iPhone 을 컨트롤러로 (Spoon/TableSpoon.swift). iPad 에서만 보인다
    @ObservedObject private var table = TableSpoonLink.shared
    @AppStorage(TableSpoonLink.enabledKey) private var tableEnabled = true

    var body: some View {
        if asSheet {
            NavigationStack {
                content
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            }
        } else {
            content
        }
    }

    /// 목록 줄에 쓰는 요약 ("Xbox 컨트롤러 · 키보드", 없으면 "연결 안 됨")
    static func summary() -> String {
        let names = LongSpoon.connectedNames() + (KeyCapture.keyboardConnected ? ["키보드"] : [])
        return names.isEmpty ? "연결 안 됨" : names.joined(separator: " · ")
    }

    private var content: some View {
        Form {
            Section {
                if controllers.isEmpty {
                    LabeledContent("컨트롤러", value: "없음")
                } else {
                    ForEach(controllers.indices, id: \.self) { i in
                        LabeledContent("컨트롤러", value: controllers[i])
                    }
                }
                LabeledContent("키보드", value: keyboard ? "연결됨" : "없음")
            } header: {
                Text("연결된 기기")
            }

            Section {
                NavigationLink {
                    KeyMapView(dish: dish)
                } label: {
                    LabeledContent {
                        Text(keyMapSummary)
                    } label: {
                        Label("키 설정", systemImage: "keyboard.badge.ellipsis")
                    }
                }
            } footer: {
                Text("컨트롤러 버튼과 키보드 키가 게임에서 하는 일을 바꿔요.")
            }

            if watch.supported || TableSpoon.canHost {
                Section {
                    if watch.supported {
                        Toggle(isOn: $watchEnabled) {
                            Text("애플워치로 조작")
                            Text("워치의 빙수 앱 버튼과 크라운으로 조작해요. 메뉴·배틀 같은 턴제 조작에 알맞아요. 필드 이동은 조금 늦을 수 있어요")
                        }
                        .onChange(of: watchEnabled) { _, _ in watch.refreshContext() }
                        LabeledContent("애플워치", value: watch.statusLabel)
                    }
                    if TableSpoon.canHost {
                        Toggle(isOn: $tableEnabled) {
                            Text("iPhone 을 컨트롤러로")
                            Text("iPhone 의 빙수 홈에서 게임패드 단추를 누르면 이 iPad 를 찾아요. 같은 Wi-Fi 나 블루투스 범위 안에서만 돼요. 연결되면 가상 패드는 숨겨져요")
                        }
                        .onChange(of: tableEnabled) { _, _ in table.refresh() }
                        LabeledContent("iPhone 컨트롤러", value: table.statusLabel)
                    }
                } header: {
                    Text("다른 기기로 조작")
                }
            }

            Section {
                Text("다중 모드 패드(8BitDo·IINE 등)는 스위치(Pro 컨트롤러)·PlayStation·Xbox 모드로 켜면 연결돼요. DirectInput·안드로이드 모드는 iOS가 인식하지 않아요. 컨트롤러가 연결되면 가상 패드는 숨겨져요.")
                Text("서드파티 패드는 앱의 진동 세기를 따르지 않는 경우가 많아요. 그럴 땐 패드 자체 진동 단계로 조절하세요(IINE: 스위치 모드에서 IINE 앱 또는 터보+오른쪽 스틱, PlayStation·Xbox 모드에서는 조절 안 됨). 진동 세기는 설정 › 소리·진동에 있어요.")
            } header: {
                Text("패드 연결 안내")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("컨트롤러·키보드")
        .navigationBarTitleDisplayMode(.inline)
        // 일시정지에서 열었을 때 실제 컨트롤러 입력이 뒤의 메뉴·게임으로 가지 않게 (키 설정 화면과 같은 규칙)
        .onAppear { capture.screenAppeared() }
        .onDisappear { capture.screenDisappeared() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in controllers = LongSpoon.connectedNames() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in controllers = LongSpoon.connectedNames() }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in keyboard = KeyCapture.keyboardConnected }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in keyboard = KeyCapture.keyboardConnected }
    }

    private var keyMapSummary: String {
        _ = prefsStore.all
        if let dish { return store.usesOwn(dish.id) ? "이 게임만" : "모든 게임 설정" }
        // 저장값 모양이 아니라 실제로 하는 일로 본다 (같은 버튼으로 둔 줄이 남아 있어도 "기본")
        let m = store.global
        let padChanged = KeyMap.remappable.contains { m.target(pad: $0) != .pad($0) }
        if padChanged { return "바꿈" }
        if m.keys.isEmpty { return "기본" }
        return KeyProfile.all.first(where: { m.matches($0) })?.title ?? "바꿈"
    }
}
