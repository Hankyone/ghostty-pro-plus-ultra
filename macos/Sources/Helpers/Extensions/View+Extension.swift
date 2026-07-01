import SwiftUI

extension View {
    func innerShadow<S: Shape, ST: ShapeStyle>(
        using shape: S = Rectangle(),
        stroke: ST = Color.black,
        width: CGFloat = 6,
        blur: CGFloat = 6
    ) -> some View {
        return self
            .overlay(
                shape
                    .stroke(stroke, lineWidth: width)
                    .blur(radius: blur)
                    .mask(shape)
            )
    }
}

extension View {
    func pointerStyleFromCursor(_ cursor: NSCursor) -> some View {
        if #available(macOS 15.0, *) {
            return self.pointerStyle(.image(
                Image(nsImage: cursor.image),
                hotSpot: .init(x: cursor.hotSpot.x, y: cursor.hotSpot.y)
            ))
        } else {
            return self
        }
    }
}

extension View {
    /// Adds a `WindowDragGesture` to the view on macOS 15+.
    /// This lets users drag the window by clicking and dragging on
    /// blank areas of the view. Child gestures (onTapGesture, onDrag,
    /// Button actions) take priority, so interactive elements still
    /// work normally. ScrollView's native scroll handling (NSScrollView)
    /// is also unaffected since `WindowDragGesture` is a system gesture
    /// that coexists with AppKit's event handling.
    @ViewBuilder
    func windowDragIfAvailable() -> some View {
        if #available(macOS 15.0, *) {
            self
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        } else {
            self
        }
    }
}
