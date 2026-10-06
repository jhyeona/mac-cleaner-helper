import AppKit
import SwiftUI

struct CleanupBasketView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("정리 바구니").font(.biu(.title2, weight: .bold))
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isPreparingCleanup)
            }
            Text("\(model.selectedItems.count)개 · 예상 정리 용량 \(ByteCountFormatter.string(fromByteCount: model.selectedSize, countStyle: .file))")
                .font(.biu(.headline))
            Text("분석을 다시 해도 담아둔 항목은 유지됩니다. 실행 전 현재 경로와 정리 가능 여부를 다시 확인합니다.")
                .font(.biu(.caption)).foregroundStyle(.secondary)
            Text("휴지통 이동은 macOS가 처리합니다. 인증·권한 창이 나타나면 승인해 주세요. 취소하거나 실패한 항목은 바구니에 남습니다.")
                .font(.biu(.caption)).foregroundStyle(.secondary)
            if model.selectedItems.isEmpty {
                ContentUnavailableView("바구니가 비어 있어요", systemImage: "basket",
                                       description: Text("정리 후보나 용량 탐색에서 항목을 담아 주세요."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.selectedItems.sorted { $0.size > $1.size }) { item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.name).font(.biu(.headline))
                                RiskBadge(risk: item.assessment.risk)
                            }
                            Text(item.path).font(.biu(.caption)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(item.assessment.impact).font(.biu(.caption)).foregroundStyle(.secondary)
                            ForEach(Array(model.preparationIssues.filter { $0.path == item.path }.enumerated()), id: \.offset) { _, issue in
                                Label(issue.message, systemImage: "exclamationmark.triangle")
                                    .font(.biu(.caption)).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                            .font(.biu(.callout).monospacedDigit())
                        Button { model.revealInFinder(item) } label: {
                            Image(systemName: "folder").biuIconHitTarget()
                        }
                        .help("Finder에서 보기")
                        Button("빼기") { model.removeFromBasket(item.id) }
                            .disabled(model.isPreparingCleanup || model.isCleaning)
                    }
                    .padding(.vertical, 6)
                }
            }
            if model.isPreparingCleanup {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("정리할 항목을 검증하고 있어요…")
                }
            } else if model.isScanning {
                Text("분석이 끝나면 정리할 수 있어요. 바구니에서 항목을 빼는 것은 지금도 가능합니다.")
                    .font(.biu(.caption)).foregroundStyle(.secondary)
            }
            HStack {
                Button("바구니 비우기") { model.clearBasket() }
                    .disabled(model.selectedItems.isEmpty || model.isPreparingCleanup || model.isCleaning)
                    .help("선택만 해제하며 파일은 변경하지 않습니다.")
                Spacer()
                Button("정리 전 확인") { model.prepareSelectedCleanup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedItems.isEmpty || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 700, height: 560)
        .interactiveDismissDisabled(model.isPreparingCleanup)
    }
}

struct ScanIssuesView: View {
    let issues: [ScanIssue]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [ScanIssue] {
        issues.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) || $0.message.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("읽지 못한 항목").font(.biu(.title2, weight: .bold))
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("읽지 못한 경로는 건너뛰었습니다. 저장된 오류는 최대 200개까지 표시합니다.")
                .font(.biu(.caption)).foregroundStyle(.secondary)
            TextField("경로 또는 오류 검색", text: $search).textFieldStyle(.roundedBorder)
            List(Array(filtered.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.path).font(.biu(.callout)).textSelection(.enabled)
                    Text(issue.message).font(.biu(.caption)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Text("\(filtered.count)개 표시").font(.biu(.caption)).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 680, height: 480)
    }
}
