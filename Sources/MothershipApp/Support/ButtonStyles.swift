import SwiftUI

/// Compact pill button that keeps its color when the window isn't key (AppKit's
/// prominent bezels go gray then, which reads as "disabled" on an urgent card).
struct PillButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var foreground: Color = .white
    var height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(foreground))
            .padding(.horizontal, 10)
            .frame(height: height)
            .background {
                if let tint {
                    shape.fill(tint.gradient)
                } else {
                    shape.fill(Color.primary.opacity(0.08))
                }
            }
            .overlay {
                shape.strokeBorder(Color.primary.opacity(tint == nil ? 0.10 : 0), lineWidth: 1)
            }
            .brightness(configuration.isPressed ? -0.08 : 0)
            .contentShape(shape)
    }
}
