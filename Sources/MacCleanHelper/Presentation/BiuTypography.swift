import AppKit
import CoreText
import SwiftUI

enum BiuTypography {
    static let postScriptName = "TerrarumSansBitmap-Regular"
    static let resourceName = "TerrarumSansBitmap"

    static var resourceURL: URL? {
        Bundle.module.url(forResource: resourceName, withExtension: "otf", subdirectory: "Fonts")
            ?? Bundle.module.url(forResource: resourceName, withExtension: "otf")
    }

    @discardableResult
    static func registerBundledFont() -> Bool {
        guard let resourceURL else { return false }

        var registrationError: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(
            resourceURL as CFURL,
            .process,
            &registrationError
        )

        // Core Text reports a duplicate-registration error when previews or tests
        // initialize the app more than once. Availability is the source of truth.
        return registered || NSFont(name: postScriptName, size: 13) != nil
    }

    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom(postScriptName, size: pointSize(for: style), relativeTo: style)
            .weight(weight)
    }

    private static func pointSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        // Terrarum의 CJK 글리프는 시스템 폰트보다 em 박스 안에서 작게 보인다.
        // 동일한 숫자를 그대로 쓰지 않고 실제 화면에서 13–16pt 본문으로
        // 읽히도록 한 단계 크게 보정한다.
        case .largeTitle: 38
        case .title: 32
        case .title2: 26
        case .title3: 21
        case .headline: 18
        case .subheadline: 16
        case .callout: 17
        case .footnote: 14
        case .caption: 14
        case .caption2: 13
        default: 17
        }
    }
}

extension Font {
    static func biu(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        BiuTypography.font(style, weight: weight)
    }
}
