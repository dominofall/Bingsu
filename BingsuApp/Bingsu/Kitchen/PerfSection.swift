import SwiftUI

/// 이 게임 설정(게임 중) › 문제 알리기 › 성능 기록: 벤치마크, 다시 불러온 횟수, 최근 실행, fps 추이, 기록 지우기
struct PerfRecordView: View {
    let dish: Dish
    @ObservedObject private var log = PerfLogStore.shared
    @State private var confirmClear = false

    private var record: PerfRecord? { log.record(for: dish.id) }

    var body: some View {
        Form {
            Section {
                if let b = record?.benchmark {
                    LabeledContent("벤치마크", value: "\(b.quality.label) · 평균 \(Int(b.avgFps.rounded()))fps · \(b.at.formatted(date: .abbreviated, time: .omitted))")
                }
                if let rs = record?.restarts, !rs.isEmpty { PerfRestartRow(restarts: rs) }
                if let sessions = record?.sessions, let last = sessions.last {
                    PerfSessionRow(session: last)
                    if sessions.count > 1 { PerfTrend(sessions: sessions).listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)) }
                } else {
                    Text("아직 기록이 없어요").foregroundStyle(.secondary)
                }
            } footer: {
                Text("성능 기록은 화면 표시를 꺼도 항상 남아요 (최근 30번). 화질 자동은 첫 실행 벤치마크로 정해요.")
            }
            if record?.sessions.isEmpty == false {
                Section {
                    Button("기록 지우기", role: .destructive) { confirmClear = true }
                        .confirmationDialog("이 게임의 성능 기록을 지울까요?", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("기록 지우기", role: .destructive) { log.clear(dish.id) }
                        } message: { Text("다음 실행 때 벤치마크를 다시 해요") }
                }
            }
        }
        .navigationTitle("성능 기록")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.accent)
    }
}

/// 실행 한 번의 요약 한 줄
struct PerfSessionRow: View {
    let session: PerfSession

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(session.chill.color)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("최근 실행 · \(session.chill.rawValue)")
                Text("\(session.start.formatted(date: .abbreviated, time: .shortened)) · \(Self.duration(session.playSeconds)) · 화질 \(session.quality.label)\(session.fpsCap.map { " · 초당 \($0) 제한" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("평균 \(Int(session.avgFps.rounded()))fps").monospacedDigit()
                Text("최저 \(Int(session.minFps.rounded())) · p95 \(Int(session.p95ms.rounded()))ms")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    static func duration(_ s: Double) -> String {
        let m = Int(s) / 60
        return m >= 60 ? "\(m / 60)시간 \(m % 60)분" : m > 0 ? "\(m)분" : "\(Int(s))초"
    }
}

/// 게임이 처음부터 다시 뜬 기록 요약 (웹 프로세스 종료·게임 자체 새로고침)
struct PerfRestartRow: View {
    let restarts: [PerfRestart]

    var body: some View {
        let crashes = restarts.filter { $0.kind == .crash }
        let last = restarts.last!
        VStack(alignment: .leading, spacing: 2) {
            Text("다시 불러옴 \(restarts.count)번" + (crashes.count < restarts.count ? " (게임 자체 새로고침 \(restarts.count - crashes.count)번)" : ""))
            Text("최근: \(last.at.formatted(date: .abbreviated, time: .shortened)) · \(last.kind == .crash ? "메모리 부족 추정" : "게임 새로고침") · 연 지 \(PerfSessionRow.duration(last.afterSeconds)) · 화질 \(last.quality.label)" + (last.background ? " · 안 보일 때" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 최근 실행들의 평균 fps 막대 (색 = 상태)
struct PerfTrend: View {
    let sessions: [PerfSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("최근 \(sessions.count)번 평균 fps").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(sessions) { s in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(s.chill.color))
                        .frame(height: max(3, 44 * min(s.avgFps, 60) / 60))
                        .frame(maxWidth: 14)
                }
            }
            .frame(height: 44, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("최근 \(sessions.count)번 평균 fps 추이")
    }
}

/// 설정 › 화면·성능: 화면 표시, 기기, 마지막 벤치마크, 모든 기록 지우기
struct PerfSettingsSection<Extra: View>: View {
    @Binding var showPerformance: Bool
    /// 화면 쪽 설정 (일시정지 버튼 자리 등). 성능 표시 위에 붙는다
    @ViewBuilder var extra: () -> Extra
    @ObservedObject private var log = PerfLogStore.shared
    @State private var confirmClear = false

    var body: some View {
        Section {
            extra()
            Toggle(isOn: $showPerformance) {
                Text("화면에 성능 표시")
                Text("프레임 수와 기기 상태를 화면 구석에 보여줘요")
            }
            LabeledContent("기기", value: "\(PerfLogStore.deviceModel) · \(PerfLogStore.osVersion)")
            if let lb = log.latestBenchmark {
                LabeledContent("마지막 벤치마크") {
                    Text("\(lb.title) · \(lb.bench.quality.label) · 평균 \(Int(lb.bench.avgFps.rounded()))fps")
                }
            }
            if !log.all.isEmpty {
                Button("모든 성능 기록 지우기", role: .destructive) { confirmClear = true }
                    .confirmationDialog("모든 게임의 성능 기록을 지울까요?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("모두 지우기", role: .destructive) { log.clearAll() }
                    }
            }
        } header: {
            Text("화면·성능")
        } footer: {
            Text("성능 기록은 화면 표시와 상관없이 게임마다 남아요. 기기 모델·iOS 버전·수치만 기록해요.")
        }
    }
}
