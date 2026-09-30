import AppKit
import SwiftUI

extension Notification.Name {
    static let biuShowSettings = Notification.Name("Biu.showSettings")
}

@MainActor
final class BiuFloatingPanelController {
    static let shared = BiuFloatingPanelController()

    private var panel: NSPanel?

    func show(message: String, state: BiuState) {
        hide()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 214),
            styleMask: [.nonactivatingPanel, .hudWindow, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "비우"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(
            rootView: BiuFloatingPanelView(
                message: message,
                state: state,
                close: { [weak self] in self?.hide() },
                enableQuietMode: { [weak self] in
                    UserDefaults.standard.set(true, forKey: "Biu.quietMode")
                    self?.hide()
                },
                openApp: { [weak self] in self?.bringMainWindowForward() },
                openSettings: { [weak self] in
                    self?.bringMainWindowForward()
                    NotificationCenter.default.post(name: .biuShowSettings, object: nil)
                }
            )
            .environment(\.font, .biu(.body))
        )

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.maxX - panel.frame.width - 18,
                y: visibleFrame.maxY - panel.frame.height - 18
            ))
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func bringMainWindowForward() {
        hide()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .first(where: { !($0 is NSPanel) && $0.canBecomeMain })?
            .makeKeyAndOrderFront(nil)
    }
}

private struct BiuFloatingPanelView: View {
    let message: String
    let state: BiuState
    let close: () -> Void
    let enableQuietMode: () -> Void
    let openApp: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                BiuMascotView(size: 88, showsWand: state != .protecting && state != .error)
                VStack(alignment: .leading, spacing: 7) {
                    Text("비우 · \(stateTitle)").font(.biu(.headline))
                    Text(message)
                        .font(.biu(.callout))
                        .lineSpacing(2)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 10) {
                Button("조용한 모드", action: enableQuietMode)
                    .buttonStyle(.plain)
                Button(action: openSettings) {
                    Label("설정", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                Spacer()
                Button(actionTitle, action: openApp)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("닫기", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.biu(.caption))
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }

    private var stateTitle: String {
        switch state {
        case .found: "발견"
        case .caution: "주의"
        case .protecting: "보호"
        case .cleaning: "정리 중"
        case .completed: "완료"
        case .error: "오류"
        default: "도우미"
        }
    }

    private var actionTitle: String {
        switch state {
        case .scanning, .cleaning: "진행 보기"
        case .found: "후보 보기"
        case .caution: "영향 확인"
        case .protecting: "보호 이유 보기"
        case .completed: "결과 보기"
        case .error: "문제 보기"
        default: "비우 열기"
        }
    }
}
