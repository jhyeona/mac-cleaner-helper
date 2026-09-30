import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: DashboardModel
    @Binding var isComplete: Bool
    @State private var step = 0
    @AppStorage("Biu.floatingEnabled") private var floatingEnabled = false

    private let stepCount = 4

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 7) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.mint : Color.secondary.opacity(0.2))
                        .frame(width: index == step ? 34 : 16, height: 6)
                }
            }

            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.mint)
                .accessibilityHidden(true)
            Text(title).font(.biu(.largeTitle, weight: .bold)).multilineTextAlignment(.center)
            Text(message)
                .font(.biu(.title3))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            if step == 1 {
                VStack(spacing: 10) {
                    Button { model.chooseAndRegisterFolders(startScan: false) } label: {
                        Label("개발 폴더 등록", systemImage: "folder.badge.plus")
                    }
                    .font(.biu(.body, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    Text(model.folderStore.folders.isEmpty
                         ? "지금 건너뛰고 나중에 등록할 수도 있어요."
                         : "\(model.folderStore.folders.count)개 폴더를 등록했어요.")
                        .font(.biu(.caption)).foregroundStyle(.secondary)
                }
            } else if step == 2 {
                VStack(spacing: 12) {
                    Text("기본 탐지 팩 · 모두 활성화")
                        .font(.biu(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(["Apple", "Android", "Web", "Python", "Rust·Go", "Container", "IDE"], id: \.self) { name in
                            Text(name).font(.biu(.caption, weight: .medium))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(.mint.opacity(0.12), in: Capsule())
                        }
                    }
                }
            } else if step == 3 {
                Toggle("중요 이벤트에 플로팅 비우 표시", isOn: $floatingEnabled)
                    .font(.biu(.body))
                    .controlSize(.large)
                    .toggleStyle(.switch)
                    .fixedSize()
            }
            Spacer()

            HStack {
                if step > 0 {
                    Button("이전") { step -= 1 }
                        .font(.biu(.body, weight: .medium))
                }
                Spacer()
                Button(step == stepCount - 1 ? "비우 시작하기" : "계속") {
                    if step == stepCount - 1 { isComplete = true } else { step += 1 }
                }
                .font(.biu(.body, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(38)
        .frame(width: 720, height: 520)
        .interactiveDismissDisabled()
    }

    private var title: String {
        switch step {
        case 0: "내 Mac 안에서만 살펴봐요"
        case 1: "개발 폴더를 골라 주세요"
        case 2: "개발 도구의 흔적을 설명해요"
        default: "필요할 때만 비우가 나타나요"
        }
    }

    private var message: String {
        switch step {
        case 0:
            "비우는 파일명, 경로, 크기와 정리 기록을 외부로 보내지 않습니다. 네트워크 없이 분석과 정리가 동작합니다."
        case 1:
            "등록한 폴더와 직접 선택한 위치만 기본 분석합니다. 전체 디스크 분석은 별도로 선택할 때만 시작합니다."
        case 2:
            "Xcode, Android, Web, Python, 시스템 언어, 컨테이너와 IDE 캐시를 구분하고 다시 생성되는 방법과 영향을 보여줍니다."
        default:
            "플로팅 비우는 포커스를 빼앗지 않으며 발견, 주의, 완료, 오류처럼 중요한 이벤트에만 나타납니다. 언제든 닫거나 조용한 모드로 바꿀 수 있어요."
        }
    }

    private var symbol: String {
        switch step {
        case 0: "hand.raised.fill"
        case 1: "folder.badge.plus"
        case 2: "hammer.circle.fill"
        default: "sparkles.rectangle.stack.fill"
        }
    }
}
