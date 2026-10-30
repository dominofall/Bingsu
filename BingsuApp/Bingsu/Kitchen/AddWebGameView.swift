import SwiftUI

/// 게임 추가 › 주소로 웹 게임 추가. 이름과 https 주소를 받아 검증한 뒤 목록에 넣는다.
struct AddWebGameView: View {
    @EnvironmentObject private var menu: MenuBoardStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""
    @State private var error: String?
    @FocusState private var focused: Field?
    private enum Field { case title, url }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("이름", text: $title, prompt: Text("예: 내 웹 게임"))
                        .focused($focused, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focused = .url }
                    TextField("주소", text: $url, prompt: Text("https://..."))
                        .focused($focused, equals: .url)
                        .keyboardType(.URL).textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { add() }
                } header: {
                    Text("웹 게임")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error { Text(error).foregroundStyle(.red) }
                        Text("브라우저에서 바로 하는 게임의 https 주소를 넣어요. 게임마다 저장소를 따로 두어 로그인과 진행이 유지돼요. 자체 터치 조작이 있는 게임은 가상 패드가 숨겨지고, 일시정지 시트에서 켤 수 있어요.")
                    }
                }
            }
            .navigationTitle("주소로 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("추가") { add() }.disabled(title.isEmpty || url.isEmpty) }
            }
            .onAppear { focused = .title }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        do {
            try menu.addWebGame(title: title, url: url)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
