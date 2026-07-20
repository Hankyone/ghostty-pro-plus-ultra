import SwiftUI

/// The app icon shown in the About window: this fork's crown icon with a
/// subtle hover-scale and press-bounce.
///
/// This previously cycled through Ghostty's upstream icon *styles* (blueprint,
/// chalkboard, glass, etc.), but those style image assets aren't bundled in
/// this fork, so every variant except the official one rendered blank. Instead
/// we show the fork's actual branded icon statically, with a bit of life on
/// interaction.
struct AboutIconView: View {
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Image("AppIconImage")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 128)
            .scaleEffect(isPressed ? 0.94 : (isHovering ? 1.06 : 1.0))
            .shadow(
                color: .black.opacity(isHovering ? 0.28 : 0.16),
                radius: isHovering ? 14 : 9,
                y: isHovering ? 7 : 4
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.62), value: isHovering)
            .animation(.spring(response: 0.28, dampingFraction: 0.5), value: isPressed)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }
            .onTapGesture {
                // Quick press-in, then spring back for a subtle bounce.
                isPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    isPressed = false
                }
            }
            .accessibilityLabel("Ghostty Pro Plus Ultra icon")
    }
}
