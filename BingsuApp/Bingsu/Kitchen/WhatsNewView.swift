import SwiftUI

/// "새로운 기능"(화면 표기; 코드명 WhatsNew): 업데이트 뒤 처음 켤 때 홈 위에 한 번 띄우는 작은 시트 (2026-11-10 사용자 요청, 빌드 33 부터).
/// 사용자 결정: 자세한 글은 사이트 패치노트(bingsu.domino.kim/notes)가 맡고, 여기는 **빌드마다 핵심 세 줄 이하**만. 전체 화면은 방해가 커서 안 씀.
/// 글은 빌드마다 `notes` 맨 위에 더한다. 심사관·테스터가 보는 글이므로 특정 게임 이름은 쓰지 않는다.
/// 한 건의 형식은 **제목 · 한 줄(`message`, 사용자가 직접 씀) · 요점 셋 이하 · 행동 링크(`action`)** 로 고정한다.
/// 같은 틀로 설문·Q&A 안내도 띄울 수 있게 (링크만 bingsu.domino.kim 의 설문·Q&A 주소로 바꾼다). 사이트 패치노트도 같은 형식을 따른다.
/// 마지막으로 본 빌드(`seenKey`)보다 큰 빌드의 글을 모아 보여 준다. 처음 설치(게임 없음)에는 띄우지 않고 본 것으로 적는다.
/// "확인"·바깥 터치·쓸어내리기는 닫기만 한다 → 다음에 켤 때 다시 뜬다. "다시 보지 않기"를 눌러야 이 빌드까지를 본 것으로 적어
/// 그 내용은 다시 안 뜬다 (새 빌드가 오면 그 빌드 글만 다시 뜸). 아예 끄는 것은 설정 › 새로운 점의 스위치. 2026-11-10 사용자 결정
enum WhatsNew {
    struct Item: Identifiable {
        let symbol: String
        let text: String
        var id: String { text }
    }
    /// 하단 링크. 시트에는 빌드의 `action`(기본 패치노트, 설문이면 그 주소)과 Q&A 게시판이 늘 나란히 있다 — "불편한 점은 Q&A로" 가 어디인지 바로 보이게
    struct Action {
        let label: String
        let symbol: String
        let url: URL
        static let notes = Action(label: "자세한 내용", symbol: "safari", url: WhatsNew.notesURL)
        static func survey(_ url: URL) -> Action { Action(label: "설문 참여", symbol: "checklist", url: url) }
        static let qna = Action(label: "Q&A 게시판", symbol: "bubble.left.and.bubble.right", url: WhatsNew.qnaURL)
    }
    struct Note: Identifiable {
        let build: Int
        let title: String
        /// 빌드 숫자 옆에 붙는 한 줄. 사용자(개발자)가 그 빌드의 느낌을 직접 쓴다. 비우면 안 보임
        var message: String = ""
        let items: [Item]
        var action: Action = .notes
        var id: Int { build }
    }

    static let seenKey = "bingsu.whatsNewSeen"
    /// 새 빌드마다 띄울지 (기본 켬). 설정 › 새로운 점에서 끈다
    static let enabledKey = "bingsu.whatsNewPopup"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    /// 이 빌드 전의 변화는 보여 주지 않는다
    static let firstBuild = 33
    /// 자세한 글 · 사이트의 Q&A 게시판
    static let notesURL = URL(string: "https://bingsu.domino.kim/notes/")!
    static let qnaURL = URL(string: "https://bingsu.domino.kim/qna/")!

    /// 새 빌드는 맨 위에. 빌드마다 세 줄 이하
    static let notes: [Note] = [
        // 48~52 글은 사용자 문장 (2026-11-19). 48·49·50 은 내부 빌드, 외부는 52(47 → 52)라 네 글을 함께 본다. 51 은 올렸지만 외부로 내지 않고 52 로 다시 냄 (사용자 2026-11-19)
        Note(build: 52, title: "게임 진동 업데이트", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "gamecontroller", text: "빙수가 진동을 지원하지 않는 게임들의 진동 지원 범위가 넓어졌습니다."),
            Item(symbol: "waveform", text: "포켓몬 팬게임에서 여러 상황을 빙수가 인식하여 상황에 맞게 진동이 출력됩니다."),
        ]),
        Note(build: 50, title: "iPhone Duo 지원", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "iphone", text: "빙수가 이제 iPhone Duo를 지원합니다."),
            Item(symbol: "rectangle.split.1x2", text: "iPhone Duo에 맞는 화면을 새롭게 디자인했습니다. 접힌 상태, 텐트 상태, 반쯤 접힌 상태, 펼친 상태 각각에서 나타나는 화면이 다릅니다."),
            Item(symbol: "camera", text: "Duo 전면 카메라가 게임 화면을 가리지 않도록 화면 크기를 조절하는 기능을 추가했습니다."),
        ]),
        Note(build: 49, title: "빠른 저장, 자동 저장 추가", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "bolt", text: "일시정지 화면에서 바로 저장하고 불러올 수 있습니다."),
            Item(symbol: "clock.arrow.circlepath", text: "자동저장 기능이 추가되었습니다."),
            Item(symbol: "info.circle", text: "세이브에 맵 이름, 플레이 시간, 파티가 함께 남아 어떤 세이브인지 알아볼 수 있습니다."),
        ]),
        Note(build: 48, title: "세이브 관리 기능 추가", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "externaldrive", text: "저장 기능이 업그레이드 되었습니다. 이제 PC 나 다른 앱에서 하던 세이브본을 적용할 수 있고, 외부로 세이브본을 내보낼 수 있습니다."),
        ]),
        // 47 은 외부 빌드(44 → 47). 제목·요점은 사용자 결정 "크래시 수정, 커스텀 버튼 추가" (2026-11-17)
        Note(build: 47, title: "크래시 수정, 커스텀 버튼 추가", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "ladybug", text: "게임을 저장 데이터까지 삭제할 때 앱이 종료되던 문제를 수정했습니다."),
            Item(symbol: "plus.square.dashed", text: "배치 편집 › 요소 추가 › 커스텀 키 추가에서 키보드 키나 버튼을 가상 패드에 하나 더 놓을 수 있습니다."),
        ]),
        // 45·46 은 내부 빌드, 제목은 사용자 결정 "기타 보안 패치" (2026-11-15). 47 과 함께 외부로 보인다.
        // 한 줄 설명은 사용자 문장 (2026-11-17). 46 의 "zip 파일 속 게임" = RPG Maker 게임 파일 접근 제한(fence)
        Note(build: 46, title: "기타 보안 패치", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "lock.shield", text: "zip 파일 보안 패치를 적용했습니다. 악의적인 목적으로 만든 zip 파일 속 게임이 다른 게임이나 앱 설정에 접근하지 못하도록 막았습니다."),
        ]),
        Note(build: 45, title: "기타 보안 패치", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "lock.shield", text: "웹 게임 보안 패치를 적용했습니다. 비밀번호 입력, 카메라, 마이크 사용 시 확인 창이 뜰 수 있습니다."),
        ]),
        // 41·42 제목은 사용자 문장 (2026-11-13). 41 은 내부 테스트만 나가서 42 와 함께 외부로 나간다. 41 항목도 사용자 문장(메뉴 이름만 앱에 맞춤)
        // 44 글은 사용자 문장 (2026-11-15). 외부 테스터는 40 → 44 로 와 42·43·44 글을 함께 본다
        Note(build: 44, title: "컨트롤러 및 키보드 키 설정 기능 추가", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "keyboard", text: "이제 설정 › 컨트롤러·키보드에서 키 매핑을 수정할 수 있습니다. 게임 중에는 ❄ › 컨트롤러·키보드에서도 바로 바꿀 수 있습니다."),
        ]),
        // 42·43 글은 사용자 문장 (2026-11-15). 42·43 은 내부 빌드, 외부는 44 에서 40 → 44 로 와 42·43·44 글을 함께 본다.
        // 41(임시 키보드)은 42 가 대신해 뺐다 — 없는 메뉴(❄ › 키보드)를 안내하지 않게
        Note(build: 43, title: "패치·업데이트 기능 업그레이드, 화면 위치 수정", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "square.stack.3d.up", text: "업데이트와 패치 적용을 하나로 합쳤습니다. 게임을 길게 누르기 › 업데이트에서 새 버전 zip 이나 한글 패치처럼 바뀐 파일만 든 zip 을 고르면 알맞게 적용됩니다. 적용한 패치는 게임 정보 › 패치 되돌리기로 되돌릴 수 있습니다."),
            Item(symbol: "rectangle.center.inset.filled", text: "RPG Maker XP 기반 게임에서 패치를 적용한 뒤 게임 화면이 한쪽으로 치우쳐 나오던 현상을 수정했습니다. 이제 화면이 정중앙에 나오게 됩니다."),
        ]),
        Note(build: 42, title: "키보드 입력 UI 업데이트", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "keyboard", text: "RPG Maker XP 기반 게임의 이름 입력 화면에서 게임 키보드가 자동으로 나타나도록 수정했습니다"),
        ]),
        // 40 글은 사용자 문장 (2026-11-11). 외부 테스터는 36 → 40 이라 아래 37·38 글도 함께 뜬다 (38·39 는 내부 테스트만)
        Note(build: 40, title: "zip 불러오기 개선", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "doc.zipper", text: "zip 을 불러오는 과정에서 윈도우 파일 형식과 iOS 파일 형식이 달라 충돌하던 문제를 해결했습니다"),
        ]),
        // 38 글의 두 줄은 사용자 문장 (2026-11-11)
        Note(build: 38, title: "터치 조작과 게임 정보", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "hand.tap", text: "터치 조작 게임 기능 개선"),
            Item(symbol: "info.circle", text: "게임 정보 기능 추가"),
        ]),
        Note(build: 37, title: "Electron 호환 1차", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "shippingbox", text: "Electron 호환 1차 작업을 진행했습니다"),
            Item(symbol: "plus.circle", text: "더 많은 게임 추가가 가능합니다"),
        ]),
        Note(build: 36, title: "워치 기능 최적화", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "applewatch", text: "− 는 누르고 있는 동안 눌려요(달리기). 일시정지는 + 길게. 진동은 짧게 두 번, 측정 페이지에서 끌 수 있어요"),
            Item(symbol: "eye.slash", text: "워치 버튼이 오면 가상 패드가 숨겨지고 화면 구석 단추로 다시 꺼내요. 워치 앱을 나가면 돌아와요"),
            Item(symbol: "sun.max", text: "게임 중에는 iPhone 화면이 저절로 꺼지지 않아요"),
        ]),
        Note(build: 35, title: "새로운 기능 알림 다듬기", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "bell.slash", text: "\"다시 보지 않기\"를 누를 때까지 켤 때마다 떠요. 다음 빌드가 오면 그 빌드 것만 다시 떠요"),
            Item(symbol: "switch.2", text: "아예 끄려면 설정 › 새로운 기능의 스위치를 끄세요"),
            Item(symbol: "bubble.left.and.bubble.right", text: "Q&A 게시판 링크를 넣었어요. 설정 › 정보에서도 갈 수 있어요"),
        ]),
        Note(build: 34, title: "새로운 기능 알림 개편", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "sparkles", text: "업데이트 뒤 처음 켤 때 바뀐 점을 짧게 알려 드려요. 설정 › 정보에서 다시 볼 수 있어요"),
        ]),
        Note(build: 33, title: "애플워치 컨트롤러 연동 기능 추가", message: "불편한 점은 Q&A로", items: [
            Item(symbol: "applewatch", text: "원반 십자키가 커지고 A·B·X·Y 가 원반을 감싸는 모양이 됐어요"),
            // 36 에서 바뀐 부분(−·+ 길게 = 일시정지, 버튼별 진동)은 뺐다 — 33~35 를 건너뛴 사람이 36 글과 모순되게 읽지 않도록 (2026-11-10)
            Item(symbol: "arrow.up.arrow.down", text: "크라운을 올리면 ▲, 내리면 ▼"),
            Item(symbol: "iphone.slash", text: "워치를 쓰는 동안 iPhone 가상 패드는 숨겨져요"),
        ]),
    ]

    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// 이번에 보여 줄 글 (오래된 것부터 위에). 없거나 알림을 껐으면 빈 배열
    static func pending(_ d: UserDefaults = .standard) -> [Note] {
        guard d.object(forKey: enabledKey) as? Bool ?? true else { return [] }
        let seen = d.object(forKey: seenKey) as? Int ?? (firstBuild - 1)
        return notes.filter { $0.build > seen && $0.build <= currentBuild }.sorted { $0.build < $1.build }
    }

    static func markSeen(_ d: UserDefaults = .standard) { d.set(currentBuild, forKey: seenKey) }
}

/// 업데이트 뒤 한 번 뜨는 작은 시트: 제목, 빌드별 핵심 줄, 사이트 링크, 확인 · 다시 보지 않기. 내용 높이에 맞춘다 (`sheetHeight`).
/// 확인·쓸어내리기·바깥 터치는 닫기만 해서 다음에 다시 뜬다. "다시 보지 않기"만 본 것으로 적는다
struct WhatsNewSheet: View {
    let notes: [WhatsNew.Note]
    @Environment(\.dismiss) private var dismiss

    /// 가장 새 빌드의 한 줄과 링크를 쓴다
    private var newest: WhatsNew.Note { notes.last! }
    private var buildText: String { notes.count == 1 ? "빌드 \(notes[0].build)" : "빌드 \(notes.first!.build)–\(notes.last!.build)" }

    /// 시트 높이: 손잡이 + 머리 + 빌드마다 머리글 + 줄 수 + 링크 + 버튼 둘
    var sheetHeight: CGFloat {
        let lines = notes.reduce(0) { $0 + $1.items.count }
        return 206 + CGFloat(notes.count) * 34 + CGFloat(lines) * 46 + (notes.count > 1 ? 10 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 손잡이는 직접 그린다: 시스템 것은 위 여백이 좁다. iPad 폼 시트에는 손잡이 대신 여백만
            if UIDevice.current.userInterfaceIdiom == .pad {
                Color.clear.frame(height: 8)
            } else {
                Capsule().fill(.tertiary).frame(width: 36, height: 5).frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, -2)
            }
            HStack(spacing: 12) {
                Image(systemName: "snowflake")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("새로운 기능").font(.title3.weight(.semibold))
                    Text(newest.message.isEmpty ? buildText : "\(buildText) · \(newest.message)")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            // 여러 빌드를 건너뛰어 글이 길면(작은 iPhone) 가운데만 스크롤. 맞으면 스크롤 안 됨
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(notes) { n in
                        // 빌드 제목은 늘 보인다. 한 빌드뿐이면 번호는 머리에 있으니 제목만 (전에는 한 빌드일 때 제목이 빠졌다, 2026-11-10 피드백)
                        Text(notes.count > 1 ? "빌드 \(n.build) · \(n.title)" : n.title)
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, notes.count > 1 ? 4 : 0)
                        ForEach(n.items) { it in WhatsNewRow(item: it) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 18) {
                ForEach([newest.action, WhatsNew.Action.qna], id: \.url) { a in
                    Link(destination: a.url) { Label(a.label, systemImage: a.symbol).font(.footnote) }
                }
                Spacer(minLength: 0)
                Text("bingsu.domino.kim").font(.caption2).foregroundStyle(.tertiary)
            }
            VStack(spacing: 6) {
                Button { dismiss() } label: { Text("확인").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("다시 보지 않기") { WhatsNew.markSeen(); dismiss() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
        .tint(Palette.accent)
    }
}

/// 핵심 한 줄: 아이콘 + 글
struct WhatsNewRow: View {
    let item: WhatsNew.Item
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol).font(.body.weight(.medium)).foregroundStyle(Palette.accent).frame(width: 26, alignment: .center).padding(.top, 1)
            Text(item.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 설정 › 정보 › 새로운 점: 알림 스위치 + 지금까지의 글 전체
struct WhatsNewListView: View {
    @AppStorage(WhatsNew.enabledKey) private var popup = true

    var body: some View {
        List {
            Section {
                Toggle("새 빌드마다 알림", isOn: $popup)
            } footer: {
                Text("업데이트 뒤 처음 켤 때 바뀐 점을 짧게 띄워요.")
            }
            ForEach(WhatsNew.notes.filter { $0.build <= WhatsNew.currentBuild }) { n in
                Section {
                    ForEach(n.items) { it in WhatsNewRow(item: it).padding(.vertical, 2) }
                } header: {
                    Text("빌드 \(n.build) · \(n.title)")
                } footer: {
                    if !n.message.isEmpty { Text(n.message) }
                }
            }
            Section {
                Link(destination: WhatsNew.notesURL) { Label("자세한 내용 · bingsu.domino.kim", systemImage: "safari") }
                Link(destination: WhatsNew.qnaURL) { Label("Q&A 게시판 · bingsu.domino.kim", systemImage: "bubble.left.and.bubble.right") }
            }
        }
        .navigationTitle("새로운 기능")
        .navigationBarTitleDisplayMode(.inline)
    }
}
