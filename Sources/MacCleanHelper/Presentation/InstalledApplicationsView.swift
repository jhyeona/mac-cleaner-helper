import AppKit
import SwiftUI

@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()
    private let images = NSCache<NSString, NSImage>()
    private let load: (String) -> NSImage

    init(load: @escaping (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }) {
        self.load = load
        images.countLimit = 256
    }

    func icon(for app: InstalledApplication) -> NSImage {
        let key = "\(app.path)\u{0}\(app.version)\u{0}\(app.modifiedAt?.timeIntervalSince1970 ?? 0)" as NSString
        if let image = images.object(forKey: key) { return image }
        // NSWorkspace supplies the app's Finder icon, including the system
        // fallback for missing/unreadable icons. Never download icon assets.
        let image = load(app.path)
        images.setObject(image, forKey: key)
        return image
    }

    func removeAll() { images.removeAllObjects() }
}

struct InstalledApplicationIcon: View {
    let app: InstalledApplication
    let size: CGFloat

    var body: some View {
        Image(nsImage: ApplicationIconCache.shared.icon(for: app))
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ApplicationTableLayout {
    static let sizeWidth: CGFloat = 100
    static let statusWidth: CGFloat = 90
    static let actionWidth: CGFloat = 76
    let nameWidth: CGFloat
    var tableWidth: CGFloat { nameWidth + 306 }
    init(viewportWidth: CGFloat) { nameWidth = max(180, viewportWidth - 306) }
}

struct InstalledApplicationsView: View {
    @ObservedObject var model: InstalledApplicationsModel
    @ObservedObject var dashboard: DashboardModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("앱 관리").font(.biu(.title2, weight: .bold))
                    Spacer()
                    Button("다른 폴더…") { model.chooseFolder() }
                        .disabled(dashboard.isBusy)
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help("설치 목록과 크기 새로고침")
                        .accessibilityLabel("앱 목록 새로고침")
                        .disabled(dashboard.isBusy)
                }
                HStack {
                    TextField("앱 이름 또는 경로 검색", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("applications.search")
                    Picker("정렬", selection: $model.sort) {
                        ForEach(ApplicationSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 120)
                }
                Text("App Store 밖에서 설치한 앱도 포함합니다. 시스템 앱은 표시만 하고 보호합니다.")
                    .font(.biu(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(14)
            Divider()
            GeometryReader { geometry in
                let layout = ApplicationTableLayout(viewportWidth: geometry.size.width)
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(model.filteredApplications) { app in
                                let inBasket = dashboard.isInBasket(path: app.path)
                                let running = !model.blockers(for: app).isEmpty
                                ApplicationListRow(
                                    app: app, layout: layout, isSelected: model.selection == app.id,
                                    isInBasket: inBasket, isRunning: running, isScanning: model.isScanning,
                                    canToggle: !dashboard.isBusy && (inBasket ||
                                        (app.blockedReason == nil && !running && app.allocatedSize != nil && app.sizeError == nil)),
                                    select: { model.selection = app.id },
                                    toggleBasket: { dashboard.toggleSelection(of: app.cleanupItem) }
                                )
                                Divider()
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Text("앱 이름").frame(width: layout.nameWidth, alignment: .leading)
                                Text("실제 크기").frame(width: ApplicationTableLayout.sizeWidth, alignment: .trailing)
                                Text("상태").frame(width: ApplicationTableLayout.statusWidth)
                                Text("바구니").frame(width: ApplicationTableLayout.actionWidth)
                            }
                            .font(.biu(.caption, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 10)
                            .frame(width: layout.tableWidth).background(.bar)
                        }
                    }.frame(width: layout.tableWidth)
                }
                .overlay {
                    if model.filteredApplications.isEmpty {
                        Text(model.isScanning ? "설치된 앱을 찾는 중…" : "표시할 앱이 없습니다. 검색어나 검색 위치를 확인하세요.")
                            .font(.biu(.callout)).foregroundStyle(.secondary).padding()
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if model.isScanning { ProgressView().controlSize(.small) }
                    Text(model.status).font(.biu(.caption))
                    Spacer(minLength: 4)
                    if model.isScanning { Button("중단") { model.cancel() } }
                }
                Text("기본 앱 폴더 + Spotlight 검색 · 누락된 위치는 ‘다른 폴더’로 추가하세요. CLI 도구는 포함하지 않습니다.")
                    .font(.biu(.caption2)).foregroundStyle(.secondary)
                if !model.issues.isEmpty {
                    DisclosureGroup("확인하지 못한 위치 \(model.issues.count)개") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                                    Text("\(issue.path)\n\(issue.message)")
                                        .font(.biu(.caption2)).textSelection(.enabled)
                                }
                            }
                        }.frame(maxHeight: 100)
                    }
                }
            }.padding(12)
        }
        .onAppear { model.loadIfNeeded() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            model.refreshRunningApplications()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            model.refreshRunningApplications()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.cancel()
        }
    }
}

struct ApplicationListRow: View {
    let app: InstalledApplication
    let layout: ApplicationTableLayout
    let isSelected: Bool
    let isInBasket: Bool
    let isRunning: Bool
    let isScanning: Bool
    let canToggle: Bool
    let select: () -> Void
    let toggleBasket: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        InstalledApplicationIcon(app: app, size: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.biu(.callout, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            Text(app.path).font(.biu(.caption2)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(width: layout.nameWidth, alignment: .leading).clipped()
                    Text(app.allocatedSize == nil && app.sizeError == nil && !isScanning ? "미계산" : app.formattedSize)
                        .font(.biu(.caption)).monospacedDigit().lineLimit(1)
                        .frame(width: ApplicationTableLayout.sizeWidth, alignment: .trailing)
                    Text(app.blockedReason != nil ? "삭제 불가" : isRunning ? "실행 중" : app.sizeError != nil ? "부분 크기" : "확인 필요")
                        .font(.biu(.caption)).foregroundStyle(app.blockedReason != nil ? .secondary : .primary)
                        .lineLimit(1).frame(width: ApplicationTableLayout.statusWidth)
                }.frame(height: 58).contentShape(Rectangle())
            }.buttonStyle(.plain).help(app.path)
            Button(isInBasket ? "빼기" : "담기", action: toggleBasket)
                .buttonStyle(.bordered).disabled(!canToggle)
                .frame(width: ApplicationTableLayout.actionWidth)
                .accessibilityLabel("\(app.name) 바구니 \(isInBasket ? "빼기" : "담기")")
        }
        .padding(.horizontal, 8).frame(width: layout.tableWidth, height: 58)
        .background(isSelected ? Color.mint.opacity(0.13) : Color.clear)
    }
}

struct InstalledApplicationDetailView: View {
    @ObservedObject var model: InstalledApplicationsModel
    @ObservedObject var dashboard: DashboardModel

    var body: some View {
        if let app = model.selectedApplication {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InstalledApplicationIcon(app: app, size: 56)
                    Text(app.name).font(.biu(.title2, weight: .bold)).textSelection(.enabled)
                    Text("버전 \(app.version)").font(.biu(.callout)).foregroundStyle(.secondary)
                    LabeledContent("앱 본체", value: app.formattedSize)
                    if let logical = app.logicalSize {
                        LabeledContent("논리 크기", value: ByteCountFormatter.string(fromByteCount: logical, countStyle: .file))
                    }
                    Text(app.path).font(.biu(.caption)).textSelection(.enabled)
                    if let identifier = app.bundleIdentifier {
                        Text(identifier).font(.biu(.caption2)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Divider()
                    if let reason = app.blockedReason {
                        Label(reason, systemImage: "lock.shield").foregroundStyle(.secondary)
                    }
                    if let error = app.sizeError {
                        Label("크기를 확인하지 못한 항목이 있어 삭제를 막았습니다. 새로고침해 주세요.\n\(error)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    let blockers = model.blockers(for: app)
                    if !blockers.isEmpty {
                        Label("먼저 종료하세요: \(blockers.joined(separator: ", "))", systemImage: "pause.circle")
                            .foregroundStyle(.orange)
                    }
                    Text("앱 본체만 휴지통으로 이동합니다. 문서·설정·로그인 정보는 그대로 둡니다. 휴지통을 비워야 실제 디스크 여유 공간이 늘어납니다.")
                    Text("필요한 경우 macOS가 인증이나 앱 관리 권한 승인을 요청합니다. 비우는 암호를 저장하거나 권한을 자동 승인하지 않습니다.")
                        .foregroundStyle(.secondary)
                    Text("VPN·보안 프로그램·드라이버처럼 별도 제거 도구가 있는 앱은 제작사의 제거 도구를 사용하세요. 앱 본체만 지우면 서비스가 남을 수 있습니다.")
                        .foregroundStyle(.secondary)
                    Button("삭제 준비…", role: .destructive) {
                        if !dashboard.isInBasket(path: app.path) { dashboard.toggleSelection(of: app.cleanupItem) }
                        if dashboard.isInBasket(path: app.path) { dashboard.showBasket = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(dashboard.isBusy || app.blockedReason != nil || !blockers.isEmpty
                              || app.allocatedSize == nil || app.sizeError != nil)
                    .accessibilityIdentifier("applications.prepare-removal")
                    Text("바구니에서 대상을 다시 확인한 후 실행합니다.")
                        .font(.biu(.caption2)).foregroundStyle(.secondary)
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                    }
                }
                .font(.biu(.callout))
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            BiuEmptyState(title: "앱을 선택하세요", systemImage: "square.grid.2x2",
                          description: "설치 위치와 용량을 확인하고, 사용하지 않는 앱을 삭제할 수 있습니다.")
        }
    }
}
