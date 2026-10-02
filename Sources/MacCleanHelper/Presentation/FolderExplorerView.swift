import AppKit
import SwiftUI

struct FolderExplorerContentView: View {
    @ObservedObject var explorer: FolderExplorerModel
    @ObservedObject var dashboard: DashboardModel
    @State private var showIssues = false
    @State private var showPathEntry = false
    @State private var pathInput = ""

    var body: some View {
        VStack(spacing: 0) {
            if explorer.currentURL == nil {
                startView
            } else {
                controls
                Divider()
                ExplorerFolderSummaryView(summary: explorer.currentFolderSummary)
                Divider()
                statusBanner
                entryTable
                if explorer.isScanning || !explorer.issues.isEmpty {
                    Divider()
                    progressBar
                }
            }
        }
        .sheet(isPresented: $showIssues) { ScanIssuesView(issues: explorer.issues) }
        .sheet(isPresented: $showPathEntry) {
            VStack(alignment: .leading, spacing: 16) {
                Text("폴더 경로로 이동").font(.biu(.headline))
                TextField("예: ~/Library/Caches", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { openEnteredPath() }
                HStack {
                    Button("취소", role: .cancel) { showPathEntry = false }
                    Spacer()
                    Button("열기") { openEnteredPath() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24).frame(width: 460)
        }
        .alert("시동 볼륨을 탐색할까요?", isPresented: $explorer.showStartupDiskWarning) {
            Button("취소", role: .cancel) {}
            Button("탐색 시작") { explorer.confirmStartupDiskOpen() }
        } message: {
            Text("파일 수에 따라 오래 걸릴 수 있습니다. 관리자 권한이나 전체 디스크 접근 권한을 요구하지 않으며, 읽지 못한 항목은 오류로 표시하고 다른 볼륨으로 넘어가지 않습니다.")
        }
        .alert("용량 탐색을 계속할 수 없어요", isPresented: Binding(
            get: { explorer.errorMessage != nil },
            set: { if !$0 { explorer.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(explorer.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
    }

    private var entryTable: some View {
        GeometryReader { geometry in
            let layout = ExplorerTableLayout(viewportWidth: geometry.size.width)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    entryHeader(layout: layout)
                    Divider()
                    if explorer.visibleEntries.isEmpty, !explorer.isScanning {
                        BiuEmptyState(
                            title: explorer.searchText.isEmpty ? "빈 폴더입니다" : "검색 결과가 없습니다",
                            systemImage: "folder",
                            description: explorer.searchText.isEmpty
                                ? "표시할 바로 아래 항목이 없습니다."
                                : "다른 이름이나 경로로 검색해 보세요."
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(explorer.visibleEntries) { entry in
                                    ExplorerEntryRow(
                                        entry: entry,
                                        layout: layout,
                                        isBusy: dashboard.isPreparingCleanup || dashboard.isCleaning,
                                        assessment: explorer.cleanupItem(for: entry).assessment,
                                        isSelected: explorer.selectedPath == entry.path,
                                        isInBasket: dashboard.isInBasket(path: entry.path),
                                        select: { explorer.select(entry) },
                                        open: { explorer.enter(entry) },
                                        openPackage: { explorer.enterPackage(entry) },
                                        toggleBasket: {
                                            dashboard.toggleExplorerSelection(
                                                explorer.cleanupItem(for: entry),
                                                calculationIsComplete: entry.calculationState == .complete
                                            )
                                        }
                                    )
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .frame(width: layout.tableWidth, height: geometry.size.height, alignment: .top)
            }
        }
    }

    private var startView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("용량 탐색")
                        .font(.biu(.title, weight: .bold))
                    Text("공간을 많이 쓰는 폴더부터 살펴보고 정리할 항목을 바구니에 담으세요.")
                        .font(.biu(.body))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("다른 폴더 열기…", systemImage: "folder") { explorer.chooseFolder() }
                    pathButton
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(explorer.locations) { location in
                        Button { explorer.requestOpen(location.url) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: locationSymbol(location.kind))
                                    .font(.title2)
                                    .foregroundStyle(location.kind == .startupDisk ? Color.orange : Color.mint)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(location.title)
                                        .font(.biu(.headline, weight: .semibold))
                                        .lineLimit(1)
                                    Text(location.subtitle)
                                        .font(.biu(.caption))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("숨김 항목도 표시합니다. 패키지와 앱 번들은 하나의 항목으로 계산하며, 명시적으로 내부 보기를 선택해야 들어갑니다.")
                    .font(.biu(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                Button { explorer.showLocations() } label: {
                    Image(systemName: "square.grid.2x2").biuIconHitTarget()
                }
                    .help("시작 위치")
                Button { explorer.goBack() } label: {
                    Image(systemName: "chevron.left").biuIconHitTarget()
                }
                    .disabled(!explorer.canGoBack)
                    .help("뒤로")
                Button { explorer.goUp() } label: {
                    Image(systemName: "arrow.up").biuIconHitTarget()
                }
                    .disabled(!explorer.canGoUp)
                    .help("상위 폴더")
                breadcrumb
                Button { explorer.copyCurrentPath() } label: {
                    Image(systemName: "doc.on.doc").biuIconHitTarget()
                }
                    .help("현재 경로 복사")
                if explorer.isScanning {
                    Button(role: .destructive) { explorer.cancel() } label: {
                        Image(systemName: "stop.circle").biuIconHitTarget()
                    }
                        .help("계산 취소")
                } else {
                    Button { explorer.refresh() } label: {
                        Image(systemName: "arrow.clockwise").biuIconHitTarget()
                    }
                        .help("새로고침")
                }
            }
            HStack(spacing: 8) {
                Button { explorer.chooseFolder() } label: {
                    Image(systemName: "folder.badge.plus").biuIconHitTarget()
                }
                .help("다른 폴더 열기")
                pathButton
                TextField("이름 또는 경로 검색", text: $explorer.searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("정렬", selection: Binding(get: { explorer.sortKey }, set: { explorer.selectSortKey($0) })) {
                    ForEach(ExplorerSortKey.allCases) { key in Text(key.title).tag(key) }
                }
                .labelsHidden()
                .frame(width: 116)
                Button { explorer.sortAscending.toggle() } label: {
                    Image(systemName: explorer.sortAscending ? "arrow.up" : "arrow.down")
                        .biuIconHitTarget()
                }
                .help(explorer.sortAscending ? "오름차순" : "내림차순")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(12)
    }

    private var pathButton: some View {
        Button {
            pathInput = explorer.currentURL?.path ?? "~/"
            showPathEntry = true
        } label: {
            Image(systemName: "arrow.right.to.line").biuIconHitTarget()
        }
        .help("경로로 이동 (⌘⇧G)")
        .accessibilityLabel("경로로 이동")
        .keyboardShortcut("g", modifiers: [.command, .shift])
    }

    private func openEnteredPath() {
        guard !pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        showPathEntry = false
        explorer.openPath(pathInput)
    }

    private var breadcrumb: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(explorer.breadcrumbURLs.enumerated()), id: \.element.path) { index, url in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        Button(url.path == "/" ? "/" : url.lastPathComponent) {
                            explorer.requestOpen(url, enterPackage: true)
                        }
                        .buttonStyle(.plain)
                        .font(.biu(.caption, weight: .semibold))
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                        .id(url.path)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { proxy.scrollTo(explorer.currentURL?.path, anchor: .trailing) }
            .onChange(of: explorer.currentURL) { _, url in
                proxy.scrollTo(url?.path, anchor: .trailing)
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let stale = explorer.staleMessage {
            Label(stale, systemImage: "clock.badge.exclamationmark")
                .font(.biu(.caption))
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08))
        } else if let cachedAt = explorer.cachedAt, !explorer.isScanning {
            Label("\(cachedAt.formatted(date: .abbreviated, time: .shortened))에 계산됨 · 자동으로 다시 분석하지 않음", systemImage: "clock")
                .font(.biu(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func entryHeader(layout: ExplorerTableLayout) -> some View {
        HStack(spacing: ExplorerTableLayout.spacing) {
            Text("이름 / 유형").frame(width: layout.nameWidth, alignment: .leading)
            Text("실제 크기").frame(width: ExplorerTableLayout.allocatedWidth, alignment: .trailing)
            Text("논리 크기").frame(width: ExplorerTableLayout.logicalWidth, alignment: .trailing)
            Text("수정일").frame(width: ExplorerTableLayout.modifiedWidth, alignment: .trailing)
            Text("안전도").frame(width: ExplorerTableLayout.riskWidth, alignment: .trailing)
            Text("상태").frame(width: ExplorerTableLayout.stateWidth, alignment: .trailing)
            Text("작업").frame(width: ExplorerTableLayout.actionsWidth, alignment: .trailing)
        }
        .font(.biu(.caption, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, ExplorerTableLayout.horizontalPadding)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.25))
    }

    private var progressBar: some View {
        HStack(spacing: 9) {
            if explorer.isScanning { ProgressView().controlSize(.small) }
            Text(explorer.isScanning
                 ? "폴더 \(explorer.progress.completedDirectoryCount)/\(explorer.progress.totalDirectoryCount) · \(explorer.progress.visitedItemCount)개 확인"
                 : "\(explorer.entries.count)개 항목")
                .font(.biu(.caption).monospacedDigit())
            Spacer()
            if !explorer.issues.isEmpty {
                Button("접근 오류 \(explorer.issues.count)개") { showIssues = true }
                    .buttonStyle(.plain)
                    .font(.biu(.caption))
                    .foregroundStyle(.orange)
                    .help(explorer.issues.prefix(10).map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func locationSymbol(_ kind: ExplorerLocation.Kind) -> String {
        switch kind {
        case .home: "house"
        case .registered: "folder.badge.gearshape"
        case .startupDisk: "internaldrive"
        case .external: "externaldrive"
        }
    }
}

struct ExplorerEntryRow: View {
    let entry: ExplorerEntry
    let layout: ExplorerTableLayout
    let isBusy: Bool
    let assessment: SafetyAssessment
    let isSelected: Bool
    let isInBasket: Bool
    let select: () -> Void
    let open: () -> Void
    let openPackage: () -> Void
    let toggleBasket: () -> Void

    var body: some View {
        HStack(spacing: ExplorerTableLayout.spacing) {
            HStack(spacing: 9) {
                Image(systemName: entry.kind.symbol)
                    .foregroundStyle(entry.kind.canBrowseContents ? Color.mint : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(entry.name)
                            .font(.biu(.callout, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        if entry.isHidden {
                            Text("숨김")
                                .font(.biu(.caption2))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    Text(entry.kind.title)
                        .font(.biu(.caption2))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: layout.nameWidth, alignment: .leading)
            .clipped()
            sizeText(entry.allocatedSize).frame(width: ExplorerTableLayout.allocatedWidth, alignment: .trailing)
            sizeText(entry.logicalSize).frame(width: ExplorerTableLayout.logicalWidth, alignment: .trailing)
            Text(entry.modifiedAt?.formatted(date: .numeric, time: .omitted) ?? "—")
                .font(.biu(.caption))
                .foregroundStyle(.secondary)
                .frame(width: ExplorerTableLayout.modifiedWidth, alignment: .trailing)
            RiskBadge(risk: assessment.risk)
                .frame(width: ExplorerTableLayout.riskWidth, alignment: .trailing)
            calculationState
                .font(.biu(.caption))
                .frame(width: ExplorerTableLayout.stateWidth, alignment: .trailing)
            HStack(spacing: 5) {
                if entry.kind == .directory {
                    Button(action: open) {
                        Image(systemName: "chevron.right").biuIconHitTarget()
                    }
                        .help("폴더 열기")
                } else if entry.kind == .package {
                    Button(action: openPackage) {
                        Image(systemName: "shippingbox.and.arrow.backward").biuIconHitTarget()
                    }
                        .help("패키지 내부 보기")
                }
                Button(action: toggleBasket) {
                    Image(systemName: isInBasket ? "basket.fill" : "basket")
                        .biuIconHitTarget()
                }
                .disabled(isBusy || (!isInBasket && (assessment.risk == .avoid || entry.calculationState != .complete)))
                .help(isInBasket ? "바구니에서 빼기" : "바구니에 담기")
            }
            .buttonStyle(.plain)
            .frame(width: ExplorerTableLayout.actionsWidth, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.horizontal, ExplorerTableLayout.horizontalPadding)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.13) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.kind == .directory { open() }
        }
        .onTapGesture(count: 1, perform: select)
        .help(entry.errorMessage ?? entry.path)
        .accessibilityIdentifier("explorer.entry.\(entry.name)")
    }

    private func sizeText(_ size: Int64) -> some View {
        Text(entry.calculationState == .pending && size == 0
             ? "—"
             : ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            .font(.biu(.caption).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var calculationState: some View {
        switch entry.calculationState {
        case .calculating:
            ProgressView().controlSize(.small).help("크기 계산 중")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(entry.errorMessage ?? "계산 실패")
        case .stale:
            Text("오래됨").foregroundStyle(.orange)
        default:
            Text(entry.calculationState.title).foregroundStyle(.secondary)
        }
    }
}

struct FolderExplorerDetailView: View {
    @ObservedObject var explorer: FolderExplorerModel
    @ObservedObject var dashboard: DashboardModel

    var body: some View {
        if let entry = explorer.selectedEntry {
            let item = explorer.cleanupItem(for: entry)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: entry.kind.symbol)
                                .font(.title2)
                                .foregroundStyle(.mint)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.name).font(.biu(.title2, weight: .bold))
                                Text(entry.path)
                                    .font(.biu(.caption))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        RiskBadge(risk: item.assessment.risk)
                        HStack(spacing: 8) {
                            SizeCard(title: "실제 할당", value: ByteCountFormatter.string(fromByteCount: entry.allocatedSize, countStyle: .file))
                            SizeCard(title: "논리 크기", value: ByteCountFormatter.string(fromByteCount: entry.logicalSize, countStyle: .file))
                        }
                        Text("수정일: \(entry.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "알 수 없음")")
                            .font(.biu(.caption)).foregroundStyle(.secondary)
                        ExplanationCard(title: "판정", symbol: "shield.lefthalf.filled", text: item.assessment.reason)
                        ExplanationCard(title: "정리 영향", symbol: "waveform.path.ecg", text: item.assessment.impact)
                        if let error = entry.errorMessage {
                            ExplanationCard(title: "계산 참고", symbol: "exclamationmark.triangle", text: error)
                        }
                        if let command = explorer.commandPreview {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("터미널에서 같은 위치 확인")
                                    .font(.biu(.headline, weight: .semibold))
                                Text(command)
                                    .font(.biu(.caption).monospaced())
                                    .textSelection(.enabled)
                                Button("명령 복사") { explorer.copyCommand() }
                                    .buttonStyle(.bordered)
                                Text("명령은 복사만 하며 비우가 셸을 실행하지 않습니다.")
                                    .font(.biu(.caption2))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(13)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
                        }
                    }
                    .padding(20)
                }
                Divider()
                HStack {
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                    }
                    Spacer()
                    Button(dashboard.isInBasket(path: entry.path) ? "바구니에서 빼기" : "바구니에 담기") {
                        dashboard.toggleExplorerSelection(
                            item,
                            calculationIsComplete: entry.calculationState == .complete
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(dashboard.isPreparingCleanup || dashboard.isCleaning ||
                              (!dashboard.isInBasket(path: entry.path) && (item.assessment.risk == .avoid || entry.calculationState != .complete)))
                }
                .padding(12)
                .background(.bar)
            }
        } else {
            BiuEmptyState(
                title: "탐색 항목을 선택하세요",
                systemImage: "externaldrive.badge.magnifyingglass",
                description: "실제 할당 크기와 논리 크기, 안전 판정, 같은 위치를 확인하는 du 명령을 보여드립니다."
            )
        }
    }
}
