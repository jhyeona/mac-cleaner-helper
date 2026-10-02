import Foundation

/// Header and rows use the same widths. Only the name column absorbs extra
/// space; a narrow viewport scrolls horizontally instead of removing columns.
struct ExplorerTableLayout {
    static let spacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 12
    static let minimumNameWidth: CGFloat = 160
    static let allocatedWidth: CGFloat = 76
    static let logicalWidth: CGFloat = 76
    static let modifiedWidth: CGFloat = 82
    static let riskWidth: CGFloat = 84
    static let stateWidth: CGFloat = 68
    static let actionsWidth: CGFloat = 70

    static var reservedWidth: CGFloat {
        allocatedWidth + logicalWidth + modifiedWidth + riskWidth
            + stateWidth + actionsWidth + spacing * 6 + horizontalPadding * 2
    }

    let nameWidth: CGFloat
    var tableWidth: CGFloat { nameWidth + Self.reservedWidth }

    init(viewportWidth: CGFloat) {
        nameWidth = max(Self.minimumNameWidth, viewportWidth - Self.reservedWidth)
    }
}
