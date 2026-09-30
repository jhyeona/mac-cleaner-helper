import AppKit
import SwiftUI

struct DashboardView: View {
    @StateObject private var model = DashboardModel()
    @State private var selection: CleanupItem.ID?
    @State private var showSettings = false
    @AppStorage("Biu.quietMode") private var quietMode = false
    @AppStorage("Biu.floatingEnabled") private var floatingEnabled = false
    @AppStorage("Biu.didCompleteOnboarding") private var didCompleteOnboarding = false

    private var selectedItem: CleanupItem? {
        model.items.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, showSettings: $showSettings)
        } content: {
            VStack(spacing: 0) {
                FilterBar(model: model)
                ResultListView(model: model, selection: $selection)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { ScanStatusView(model: model) }
        } detail: {
            if let selectedItem {
                CleanupDetailView(item: selectedItem, model: model)
            } else {
                BiuEmptyState(
                    title: "항목을 선택하세요",
                    systemImage: "sparkles",
                    description: "비우가 탐지 근거와 정리 영향을 설명해 드립니다."
                )
            }
        }
        .tint(.mint)
        .onChange(of: model.items) { _, items in
            if selection == nil || !items.contains(where: { $0.id == selection }) {
                selection = items.first?.id
            }
        }
        .onChange(of: model.filteredItems.map(\.id)) { _, visibleIDs in
            if let selection, !visibleIDs.contains(selection) {
                self.selection = visibleIDs.first
            }
        }
        .onChange(of: selection) { _, itemID in model.inspect(itemID) }
        .onChange(of: model.biuState) { _, state in
            let importantStates: Set<BiuState> = [.found, .caution, .protecting, .completed, .error]
            if floatingEnabled, !quietMode, importantStates.contains(state) {
                BiuFloatingPanelController.shared.show(message: model.assistantMessage, state: state)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .biuShowSettings)) { _ in
            showSettings = true
        }
        .alert("작업을 완료할 수 없어요", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
        .alert("전체 디스크를 분석할까요?", isPresented: $model.showWholeDiskWarning) {
            Button("취소", role: .cancel) {}
            Button("분석 시작") { model.confirmWholeDiskScan() }
        } message: {
            Text("파일 수에 따라 오래 걸리고 일부 영역은 macOS 권한으로 읽을 수 없습니다. 전체 디스크 접근 권한은 필수가 아니며, 읽지 못한 항목은 오류 목록에 남깁니다.")
        }
        .alert("범위가 큰 폴더를 분석할까요?", isPresented: $model.showBroadFolderWarning) {
            Button("취소", role: .cancel) {}
            Button("그래도 분석") { model.scanRegisteredFolders() }
        } message: {
            Text("홈 폴더나 디스크 전체는 파일이 많아 오래 걸릴 수 있고 개인 파일도 확인 필요 항목으로 표시될 수 있습니다. 가능하면 프로젝트가 모인 개발 폴더를 따로 등록해 주세요.")
        }
        .sheet(item: $model.confirmation) { confirmation in
            CleanupConfirmationView(confirmation: confirmation, model: model)
        }
        .sheet(item: $model.cleanupResult) { result in
            CleanupResultView(result: result, model: model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: Binding(
            get: { !didCompleteOnboarding },
            set: { if !$0 { didCompleteOnboarding = true } }
        )) {
            OnboardingView(model: model, isComplete: $didCompleteOnboarding)
        }
    }
}

private struct SidebarWideButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
            .background(
                .quaternary.opacity(configuration.isPressed ? 0.72 : 0.48),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct SidebarActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
            Text(title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct SidebarView: View {
    @ObservedObject var model: DashboardModel
    @Binding var showSettings: Bool
    @AppStorage("Biu.quietMode") private var quietMode = false
    @AppStorage("Biu.floatingEnabled") private var floatingEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BiuAssistantHeader(state: model.biuState, message: model.assistantMessage)

                    HStack(spacing: 8) {
                        MetricView(title: "재생성 가능", value: model.reclaimableSize, color: .mint)
                        MetricView(title: "바구니", value: model.selectedSize, color: .blue)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("등록한 개발 폴더").font(.biu(.caption, weight: .semibold))
                            Spacer()
                            Text("\(model.folderStore.folders.count)")
                                .font(.biu(.caption).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if model.folderStore.folders.isEmpty {
                            Text("선택한 폴더만 기본 분석합니다.")
                                .font(.biu(.caption))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.folderStore.folders.prefix(5)) { folder in
                                HStack(spacing: 6) {
                                    Label(folder.url.lastPathComponent, systemImage: folder.isStale ? "folder.badge.questionmark" : "folder")
                                        .font(.biu(.caption))
                                        .lineLimit(1)
                                        .help(folder.url.path)
                                    Spacer(minLength: 4)
                                    if isBroadScope(folder.url) {
                                        Text("범위 큼")
                                            .font(.biu(.caption2, weight: .semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))

                    VStack(spacing: 10) {
                        Button {
                            model.chooseAndRegisterFolders()
                        } label: {
                            SidebarActionLabel(title: "개발 폴더 등록", systemImage: "folder.badge.plus")
                        }
                        .font(.biu(.callout, weight: .semibold))
                        .buttonStyle(SidebarWideButtonStyle())
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("sidebar.register-folder")

                        Button { model.scanRecommendedAreas() } label: {
                            SidebarActionLabel(title: "추천 개발 영역 분석", systemImage: "wand.and.stars")
                        }
                        .font(.biu(.callout, weight: .medium))
                        .buttonStyle(SidebarWideButtonStyle())
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("sidebar.scan-recommended")

                        if model.isScanning {
                            Button(role: .destructive) { model.cancelScan() } label: {
                                SidebarActionLabel(title: "분석 취소", systemImage: "stop.circle")
                            }
                            .font(.biu(.callout, weight: .medium))
                            .buttonStyle(SidebarWideButtonStyle())
                            .accessibilityIdentifier("sidebar.cancel-scan")
                        } else if !model.folderStore.folders.isEmpty {
                            Button { model.requestRegisteredFolderScan() } label: {
                                SidebarActionLabel(title: "등록 폴더 분석", systemImage: "arrow.clockwise")
                            }
                            .font(.biu(.callout, weight: .medium))
                            .buttonStyle(SidebarWideButtonStyle())
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("sidebar.scan-registered")
                        }
                    }

                    if let receipt = model.receipts.first {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(receipt.succeeded ? "최근 정리 완료" : "최근 정리 실패", systemImage: receipt.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.biu(.caption, weight: .semibold))
                                .foregroundStyle(receipt.succeeded ? Color.green : Color.red)
                            Text("예상 \(ByteCountFormatter.string(fromByteCount: receipt.estimatedBytes, countStyle: .file))")
                                .font(.biu(.caption))
                            if let change = receipt.availableCapacityChange {
                                Text("실제 여유 공간 변화 \(ByteCountFormatter.string(fromByteCount: change, countStyle: .file))")
                                    .font(.biu(.caption)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .contentMargins(.top, 0, for: .scrollContent)

            Divider()

            VStack(spacing: 2) {
                Button { model.requestWholeDiskScan() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "internaldrive")
                            .frame(width: 18)
                        Text("전체 디스크 분석…")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.biu(.callout, weight: .medium))
                .disabled(model.isBusy)

                HStack(spacing: 8) {
                    Button { showSettings = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gearshape")
                                .frame(width: 18)
                            Text("설정")
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .font(.biu(.callout, weight: .medium))
                    .buttonStyle(.plain)

                    if floatingEnabled {
                        Button {
                            quietMode = false
                            BiuFloatingPanelController.shared.show(message: model.assistantMessage, state: model.biuState)
                        } label: {
                            Image(systemName: "sparkles.rectangle.stack")
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("플로팅 비우 다시 부르기")
                        .accessibilityLabel("플로팅 비우 다시 부르기")
                    }
                }

                Text("모든 판정은 로컬에서 수행")
                    .font(.biu(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 320)
    }

    private func isBroadScope(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == "/" || path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }
}

private struct MetricView: View {
    let title: String
    let value: Int64
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.biu(.caption2)).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: value, countStyle: .file))
                .font(.biu(.headline, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct BiuAssistantHeader: View {
    let state: BiuState
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                BiuMascotView(size: 90, showsWand: state != .protecting && state != .error)
                VStack(alignment: .leading, spacing: 2) {
                    Text("비우 Biu").font(.biu(.title2, weight: .bold))
                    Text(stateLabel).font(.biu(.caption)).foregroundStyle(.secondary)
                }
            }
            Text(message)
                .font(.biu(.callout))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.mint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("비우의 도움말: \(message)")
        }
    }

    private var stateLabel: String {
        switch state {
        case .greeting: "인사"
        case .scanning: "살펴보기"
        case .cleaning: "정리 중"
        case .found: "발견"
        case .caution: "주의"
        case .protecting: "보호"
        case .completed: "완료"
        case .error: "오류"
        case .resting: "휴식"
        }
    }
}

private struct FilterBar: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("정리 후보")
                    .font(.biu(.title3, weight: .bold))
                Spacer()
                if let lastAnalysisAt = model.lastAnalysisAt {
                    Label(
                        "마지막 \(lastAnalysisAt.formatted(date: .numeric, time: .shortened))",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.biu(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(
                        "마지막 분석 \(lastAnalysisAt.formatted(date: .complete, time: .shortened))"
                    )
                }
            }
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    TextField("이름, 경로 또는 도구 검색", text: $model.searchText)
                        .font(.biu(.callout))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                    if !model.searchText.isEmpty {
                        Button {
                            model.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("검색어 지우기")
                        .accessibilityLabel("검색어 지우기")
                    }
                }
                .frame(minWidth: 180)
                sortMenu
            }
            HStack(spacing: 10) {
                Picker("안전도", selection: $model.riskFilter) {
                    Text("모든 안전도").tag(Optional<CleanupRisk>.none)
                    ForEach(CleanupRisk.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .font(.biu(.callout))
                .controlSize(.large)
                .frame(width: 145)
                Picker("종류", selection: $model.categoryFilter) {
                    Text("모든 종류").tag(Optional<CleanupCategory>.none)
                    ForEach(CleanupCategory.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .font(.biu(.callout))
                .controlSize(.large)
                .frame(width: 140)
                Spacer()
                Text("\(model.filteredItems.count)개")
                    .font(.biu(.caption).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var sortMenu: some View {
        Menu {
            Picker("정렬 기준", selection: Binding(
                get: { model.sortKey },
                set: { model.selectSortKey($0) }
            )) {
                ForEach(CleanupSortKey.allCases) { key in
                    Text(key.title).tag(key)
                }
            }
            Divider()
            Button {
                model.toggleSortDirection()
            } label: {
                Label(
                    model.sortAscending ? "내림차순으로 바꾸기" : "오름차순으로 바꾸기",
                    systemImage: model.sortAscending ? "arrow.down" : "arrow.up"
                )
            }
        } label: {
            Color.clear
                .frame(width: 112, height: 32)
                .contentShape(Rectangle())
        }
        .controlSize(.large)
        .menuStyle(.borderlessButton)
        .frame(width: 126, height: 32)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.sortKey.compactTitle)
                    .font(.biu(.headline, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityLabel("정렬: \(model.sortKey.title), \(model.sortAscending ? "오름차순" : "내림차순")")
    }
}

private struct ResultListView: View {
    @ObservedObject var model: DashboardModel
    @Binding var selection: CleanupItem.ID?

    var body: some View {
        List(model.filteredItems, selection: $selection) { item in
            ResultRow(
                item: item,
                isInBasket: model.selectedIDs.contains(item.id),
                isDisabled: model.isBusy,
                toggle: { model.toggleSelection(of: item) }
            )
            .tag(item.id)
        }
        .overlay {
            if !model.isScanning && model.filteredItems.isEmpty {
                VStack(spacing: 18) {
                    BiuEmptyState(
                        title: emptyTitle,
                        systemImage: "folder.badge.magnifyingglass",
                        description: emptyDescription
                    )

                    if model.items.isEmpty {
                        VStack(spacing: 10) {
                            Button {
                                if model.folderStore.folders.isEmpty {
                                    model.chooseAndRegisterFolders()
                                } else {
                                    model.requestRegisteredFolderScan()
                                }
                            } label: {
                                Label(
                                    model.folderStore.folders.isEmpty ? "개발 폴더 등록" : "등록 폴더 분석",
                                    systemImage: model.folderStore.folders.isEmpty ? "folder.badge.plus" : "play.fill"
                                )
                            }
                            .font(.biu(.callout, weight: .semibold))
                            .controlSize(.large)
                            .buttonStyle(.borderedProminent)

                            Button("추천 개발 영역 분석") { model.scanRecommendedAreas() }
                                .font(.biu(.callout, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(.mint)
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 390, ideal: 470)
    }

    private var emptyTitle: String {
        guard model.items.isEmpty else { return "필터 결과가 없어요" }
        return model.folderStore.folders.isEmpty
            ? "분석할 폴더를 등록하세요"
            : "등록한 폴더를 분석해 보세요"
    }

    private var emptyDescription: String {
        guard model.items.isEmpty else { return "검색어나 필터 조건을 바꿔 보세요." }
        return model.folderStore.folders.isEmpty
            ? "선택한 폴더만 살펴보며, 파일은 변경하지 않아요."
            : "등록 정보와 지난 결과는 앱을 다시 열어도 유지됩니다."
    }

}

private struct ResultRow: View {
    let item: CleanupItem
    let isInBasket: Bool
    let isDisabled: Bool
    let toggle: () -> Void

    private var selectionSymbol: String {
        if item.assessment.risk == .avoid { return "lock.circle.fill" }
        return isInBasket ? "checkmark.circle.fill" : "circle"
    }

    private var selectionColor: Color {
        item.assessment.risk == .avoid ? Color.secondary : Color.mint
    }

    var body: some View {
        HStack(spacing: 11) {
            Button(action: toggle) {
                Image(systemName: selectionSymbol).foregroundStyle(selectionColor)
            }
            .buttonStyle(.plain)
            .disabled(item.assessment.risk == .avoid || isDisabled)
            .accessibilityLabel(isInBasket ? "정리 바구니에서 빼기" : "정리 바구니에 담기")

            Image(systemName: item.category.symbol)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.biu(.body, weight: .semibold))
                    .lineLimit(1)
                Text("\(item.candidate.tool) · \(item.category.title)")
                    .font(.biu(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.formattedSize).font(.biu(.callout).monospacedDigit())
                RiskBadge(risk: item.assessment.risk)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ScanStatusView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        if model.isBusy || !model.scanIssues.isEmpty || !model.selectedIDs.isEmpty {
            VStack(spacing: 7) {
                if model.isScanning {
                    if model.scanProgress.totalTopLevelEntries > 0 {
                        ProgressView(value: model.scanProgress.fractionCompleted)
                    } else {
                        ProgressView()
                    }
                    HStack {
                        Text("상위 \(model.scanProgress.completedTopLevelEntries.formatted())개 · 파일 \(model.scanProgress.visitedFileCount.formatted())개 확인")
                        Spacer()
                        Text(model.scanProgress.currentPath ?? "준비 중…").lineLimit(1)
                    }
                    .font(.biu(.caption)).foregroundStyle(.secondary)
                } else if model.isPreparingCleanup {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("선택한 항목의 경로와 실행 조건을 다시 확인하고 있어요.")
                    }
                    .font(.biu(.caption))
                    .foregroundStyle(.secondary)
                } else if model.isCleaning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("정리 중이에요. 완료될 때까지 앱을 종료하지 마세요.")
                    }
                    .font(.biu(.caption))
                    .foregroundStyle(.secondary)
                }
                HStack {
                    if !model.scanIssues.isEmpty {
                        Label("읽지 못한 항목 \(model.scanIssues.count)개", systemImage: "exclamationmark.triangle")
                            .font(.biu(.caption)).foregroundStyle(.orange)
                            .help(model.scanIssues.prefix(10).map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
                    }
                    Spacer()
                    if !model.selectedIDs.isEmpty {
                        Text("\(model.selectedIDs.count)개 · \(ByteCountFormatter.string(fromByteCount: model.selectedSize, countStyle: .file))")
                            .font(.biu(.callout).monospacedDigit())
                        Button("정리 바구니 검토") { model.prepareSelectedCleanup() }
                            .font(.biu(.callout, weight: .semibold))
                            .controlSize(.large)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy)
                    }
                }
            }
            .padding(10)
            .background(.bar)
        }
    }
}

private struct CleanupDetailView: View {
    let item: CleanupItem
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(item.name).font(.biu(.title, weight: .bold))
                            Text(item.path)
                                .font(.biu(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(item.path)
                        }
                        Spacer()
                        RiskBadge(risk: item.assessment.risk)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], spacing: 10) {
                        SizeCard(title: "실제 할당", value: item.candidate.formattedSize)
                        SizeCard(title: "논리적 크기", value: item.candidate.formattedLogicalSize)
                        SizeCard(title: "수정일", value: item.candidate.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "알 수 없음")
                    }

                    ExplanationCard(title: "무엇인가요?", symbol: "wrench.and.screwdriver.fill", text: "\(item.candidate.tool) · \(item.candidate.detectionReason)")
                    ExplanationCard(title: "왜 이렇게 판단했나요?", symbol: "lightbulb.max.fill", text: item.assessment.reason)
                    ExplanationCard(title: "정리하면 어떤 영향이 있나요?", symbol: "waveform.path.ecg", text: item.assessment.impact)
                    ExplanationCard(title: "복구 가능성", symbol: "arrow.uturn.backward.circle", text: item.assessment.recovery.title)
                }
                .padding(24)
            }

            Divider()
            HStack {
                Button("Finder에서 보기") { model.revealInFinder(item) }
                    .font(.biu(.callout, weight: .medium))
                Spacer()
                Button(model.selectedIDs.contains(item.id) ? "바구니에서 빼기" : "바구니에 담기") {
                    model.toggleSelection(of: item)
                }
                .font(.biu(.callout, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .disabled(item.assessment.risk == .avoid || model.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

private struct BiuEmptyState: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.biu(.headline, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(description)
                .font(.biu(.body))
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(28)
        .accessibilityElement(children: .combine)
    }
}

private struct SizeCard: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.biu(.caption)).foregroundStyle(.secondary)
            Text(value)
                .font(.biu(.callout, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .help(value)
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ExplanationCard: View {
    let title: String
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.mint).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.biu(.headline))
                Text(text)
                    .font(.biu(.body))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct CleanupConfirmationView: View {
    let confirmation: CleanupConfirmation
    @ObservedObject var model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("정리 전 마지막 확인").font(.biu(.title2, weight: .bold))
            Text("예상 확보량 \(ByteCountFormatter.string(fromByteCount: confirmation.estimatedBytes, countStyle: .file))")
                .font(.biu(.headline))
            List(confirmation.preparations, id: \.item.id) { preparation in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(preparation.item.name).font(.biu(.headline))
                        Spacer()
                        Text(preparation.action.title)
                            .font(.biu(.callout))
                            .foregroundStyle(.secondary)
                    }
                    Text(preparation.item.path).font(.biu(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    if let command = preparation.commandPreview {
                        Text(command).font(.biu(.caption).monospaced()).textSelection(.enabled)
                    }
                    if !preparation.blockingApplications.isEmpty {
                        Label("먼저 종료: \(preparation.blockingApplications.joined(separator: ", "))", systemImage: "exclamationmark.octagon")
                            .foregroundStyle(.red).font(.biu(.caption))
                    }
                }
                .padding(.vertical, 4)
            }
            Text("개인 파일은 휴지통으로 이동합니다. ‘캐시 즉시 삭제’와 공식 명령은 휴지통에서 복구할 수 없습니다.")
                .font(.biu(.caption)).foregroundStyle(.secondary)
            HStack {
                Button("취소", role: .cancel) { model.confirmation = nil; dismiss() }
                    .font(.biu(.callout, weight: .medium))
                    .controlSize(.large)
                Spacer()
                Button("위 내용을 확인하고 정리") { model.executeConfirmedCleanup() }
                    .font(.biu(.callout, weight: .semibold))
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.isCleaning
                            || confirmation.preparations.contains { !$0.blockingApplications.isEmpty }
                    )
            }
        }
        .padding(26).frame(minWidth: 700, minHeight: 500)
    }
}

private struct CleanupResultView: View {
    let result: CleanupResult
    @ObservedObject var model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        if result.failedCount == 0 { return "정리를 마쳤어요" }
        if result.succeededCount == 0 { return "정리하지 못했어요" }
        return "일부 항목만 정리했어요"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.biu(.title2, weight: .bold))
                    Text("성공 \(result.succeededCount)개 · 실패 \(result.failedCount)개")
                        .font(.biu(.headline))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("실제 항목 크기 감소")
                        .font(.biu(.caption))
                        .foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: result.reclaimedBytes, countStyle: .file))
                        .font(.biu(.title3, weight: .bold).monospacedDigit())
                }
            }

            List(result.receipts) { receipt in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(
                            receipt.succeeded ? "완료" : "실패",
                            systemImage: receipt.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill"
                        )
                        .foregroundStyle(receipt.succeeded ? Color.green : Color.red)
                        .font(.biu(.callout, weight: .semibold))
                        Spacer()
                        Text(receipt.action.title)
                            .font(.biu(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Text(receipt.path)
                        .font(.biu(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if let reason = receipt.failureReason {
                        Text(reason)
                            .font(.biu(.callout))
                            .foregroundStyle(.red)
                    }
                    if let change = receipt.availableCapacityChange {
                        Text("디스크 여유 공간 변화 \(ByteCountFormatter.string(fromByteCount: change, countStyle: .file))")
                            .font(.biu(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }

            Text("항목 크기 감소와 디스크 여유 공간 변화는 스냅샷·파일 시스템 처리 때문에 다를 수 있습니다.")
                .font(.biu(.caption))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("완료") {
                    model.cleanupResult = nil
                    dismiss()
                }
                .font(.biu(.callout, weight: .semibold))
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(minWidth: 700, minHeight: 500)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject private var folderStore: FolderBookmarkStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("Biu.quietMode") private var quietMode = false
    @AppStorage("Biu.floatingEnabled") private var floatingEnabled = false
    @State private var showHistoryDeletionWarning = false
    @State private var showImmediateDeletionWarning = false
    @State private var folderPendingRemoval: RegisteredFolder?

    init(model: DashboardModel) {
        self.model = model
        folderStore = model.folderStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("비우 설정").font(.biu(.title2, weight: .bold))
                Spacer()
                Button("완료") { dismiss() }
                    .font(.biu(.callout, weight: .semibold))
            }
            GroupBox {
                VStack(spacing: 8) {
                    HStack {
                        Spacer()
                        Button {
                            model.chooseAndRegisterFolders(startScan: false)
                        } label: {
                            Label("폴더 추가", systemImage: "plus")
                        }
                        .font(.biu(.callout, weight: .medium))
                        .disabled(model.isBusy)
                    }
                    ForEach(folderStore.folders) { folder in
                        HStack {
                            Image(systemName: "folder")
                            Text(folder.url.path)
                                .font(.biu(.callout))
                                .lineLimit(1)
                            Spacer()
                            Button(role: .destructive) { folderPendingRemoval = folder } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("등록 해제")
                            .accessibilityLabel("\(folder.url.lastPathComponent) 등록 해제")
                        }
                    }
                    if folderStore.folders.isEmpty {
                        Text("등록된 폴더가 없습니다.")
                            .font(.biu(.callout))
                            .foregroundStyle(.secondary)
                    }
                }.padding(6)
            } label: {
                Text("등록 폴더").font(.biu(.headline, weight: .semibold))
            }
            Toggle("검증된 재생성 캐시 즉시 삭제 허용", isOn: Binding(
                get: { model.allowsImmediateCacheDeletion },
                set: { enabled in
                    if enabled {
                        showImmediateDeletionWarning = true
                    } else {
                        model.allowsImmediateCacheDeletion = false
                    }
                }
            ))
                .font(.biu(.body))
                .controlSize(.large)
            Text("끄면 모든 파일 항목을 휴지통으로 이동합니다. 공식 CLI 작업은 별도로 표시됩니다.")
                .font(.biu(.caption)).foregroundStyle(.secondary)
            Toggle("조용한 모드", isOn: $quietMode)
                .font(.biu(.body))
                .controlSize(.large)
                .onChange(of: quietMode) { _, enabled in
                    if enabled {
                        BiuFloatingPanelController.shared.hide()
                    }
                }
            Toggle("중요 이벤트에 플로팅 비우 표시", isOn: $floatingEnabled)
                .font(.biu(.body))
                .controlSize(.large)
                .onChange(of: floatingEnabled) { _, enabled in
                    if enabled, !quietMode {
                        BiuFloatingPanelController.shared.show(
                            message: model.assistantMessage,
                            state: model.biuState
                        )
                    } else {
                        BiuFloatingPanelController.shared.hide()
                    }
                }
            Text("포커스를 가져오지 않는 작은 패널로 발견·주의·완료·오류 이벤트만 알려줍니다.")
                .font(.biu(.caption)).foregroundStyle(.secondary)
            GroupBox {
                HStack {
                    Text("로컬에 저장된 기록 \(model.receipts.count)개")
                        .font(.biu(.callout))
                    Spacer()
                    Button("내보내기") { model.exportReceipts() }
                        .font(.biu(.callout, weight: .medium))
                        .disabled(model.receipts.isEmpty)
                    Button("모두 삭제", role: .destructive) { showHistoryDeletionWarning = true }
                        .font(.biu(.callout, weight: .medium))
                        .disabled(model.receipts.isEmpty)
                }
                .padding(6)
            } label: {
                Text("정리 기록").font(.biu(.headline, weight: .semibold))
            }
            Spacer()
        }
        .padding(26).frame(width: 640, height: 520)
        .alert("정리 기록을 모두 삭제할까요?", isPresented: $showHistoryDeletionWarning) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { model.deleteAllReceipts() }
        } message: {
            Text("로컬 기록만 삭제되며 정리한 파일에는 영향을 주지 않습니다.")
        }
        .alert("캐시 즉시 삭제를 허용할까요?", isPresented: $showImmediateDeletionWarning) {
            Button("취소", role: .cancel) {}
            Button("허용") { model.allowsImmediateCacheDeletion = true }
        } message: {
            Text("탐지 규칙으로 재생성 가능성이 확인된 캐시만 대상이지만 휴지통에서 복구할 수 없습니다. 실행 전 정리 확인 화면에 작업 방식이 표시됩니다.")
        }
        .alert(
            "개발 폴더 등록을 해제할까요?",
            isPresented: Binding(
                get: { folderPendingRemoval != nil },
                set: { if !$0 { folderPendingRemoval = nil } }
            ),
            presenting: folderPendingRemoval
        ) { folder in
            Button("취소", role: .cancel) { folderPendingRemoval = nil }
            Button("등록 해제", role: .destructive) {
                model.removeRegisteredFolder(folder)
                folderPendingRemoval = nil
            }
        } message: { folder in
            Text("\(folder.url.path)\n폴더나 파일은 삭제하지 않고 비우의 등록 정보만 제거합니다.")
        }
    }
}

private struct RiskBadge: View {
    let risk: CleanupRisk
    private var color: Color {
        switch risk { case .safe: .green; case .review: .orange; case .avoid: .red }
    }
    var body: some View {
        Label(risk.title, systemImage: risk.symbol)
            .font(.biu(.caption, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}
