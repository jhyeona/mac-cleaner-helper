import Foundation
import SwiftUI

struct ExplorerFolderSummary {
    enum State: Equatable {
        case calculating, complete, partial, stale

        var title: String {
            switch self {
            case .calculating: "계산 중 · 현재까지 확인한 용량"
            case .complete: "계산 완료"
            case .partial: "일부만 확인됨 · 전체 용량보다 작을 수 있음"
            case .stale: "저장·중단 결과 · 새로고침 필요"
            }
        }
    }

    let allocatedSize: Int64
    let logicalSize: Int64
    let itemCount: Int
    let state: State

    init(entries: [ExplorerEntry], isScanning: Bool, isComplete: Bool, isStale: Bool, hasIssues: Bool) {
        let measured = entries.filter {
            $0.calculationState == .complete || (!isScanning && $0.calculationState == .stale)
        }
        allocatedSize = measured.reduce(0) { $0 + $1.allocatedSize }
        logicalSize = measured.reduce(0) { $0 + $1.logicalSize }
        itemCount = entries.count
        if isScanning {
            state = .calculating
        } else if isStale {
            state = .stale
        } else if !isComplete || hasIssues || entries.contains(where: {
            $0.errorMessage != nil || $0.calculationState != .complete
        }) {
            state = .partial
        } else {
            state = .complete
        }
    }
}

struct ExplorerFolderSummaryView: View {
    let summary: ExplorerFolderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("현재 폴더 총용량")
                .font(.biu(.caption, weight: .semibold))
            HStack(spacing: 16) {
                total("실제 크기", bytes: summary.allocatedSize)
                total("논리 크기", bytes: summary.logicalSize)
            }
            Text("하위 폴더 포함 · \(summary.itemCount)개 항목 · \(summary.state.title)")
                .font(.biu(.caption2))
                .foregroundStyle(summary.state == .partial || summary.state == .stale ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.mint.opacity(0.06))
        .help("검색과 무관한 현재 폴더 전체 합계입니다. 같은 볼륨의 하위 폴더를 포함하며 심볼릭 링크의 대상은 따라가지 않습니다. 실제 크기는 삭제 시 확보되는 공간과 다를 수 있습니다.")
        .accessibilityIdentifier("explorer.folder-total")
    }

    private func total(_ title: String, bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.biu(.caption)).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.biu(.callout, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}
