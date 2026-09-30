import SwiftUI

@main
struct MacCleanHelperApp: App {
    init() {
        BiuTypography.registerBundledFont()
    }

    var body: some Scene {
        WindowGroup("비우 — Mac 개발 환경 정리 도우미") {
            DashboardView()
                .frame(minWidth: 940, minHeight: 620)
                .environment(\.font, .biu(.body))
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1080, height: 720)
    }
}
