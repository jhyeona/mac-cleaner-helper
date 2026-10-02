import SwiftUI

/// Pure SwiftUI buttons keep visual bounds and hit bounds identical, including
/// after scrolling or resizing. Navigation never invokes a cleanup action.
struct SidebarSectionPicker: View {
    @Binding var selection: DashboardSection

    var body: some View {
        VStack(spacing: 4) {
            ForEach(DashboardSection.allCases, id: \.self) { section in
                Button { selection = section } label: {
                    Label(section.title, systemImage: section.symbol)
                        .font(.biu(.callout, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(selection == section ? Color.mint.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.section.\(section.rawValue)")
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("화면 선택")
    }
}
