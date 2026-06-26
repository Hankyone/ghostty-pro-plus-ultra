import SwiftUI

/// An NSHostingView subclass that prevents window dragging when clicking on the view.
///
/// By default, NSHostingViews in the titlebar allow the window to be dragged when
/// clicked. This subclass overrides `mouseDownCanMoveWindow` to return false,
/// preventing the window from being dragged when the user clicks on this view.
///
/// This is useful for titlebar accessories that contain interactive elements
/// (buttons, links, etc.) where you don't want accidental window dragging.
class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// An NSHostingView subclass that allows window dragging from blank areas
/// while still letting interactive elements (NSButton, NSTextField, etc.)
/// receive clicks normally.
///
/// `mouseDownCanMoveWindow` is checked by the window server on the view
/// returned by `hitTest`. When the hit-tested view is the hosting view
/// itself (a blank area with no AppKit subview), the window starts
/// dragging. When the hit-tested view is an NSButton (created by
/// SwiftUI's `Button`), the button's own `mouseDownCanMoveWindow`
/// (which returns `false`) takes precedence and the click is delivered
/// normally.
///
/// Important: SwiftUI gesture-based interactions (e.g. `onTapGesture`)
/// do NOT create AppKit subviews, so they will not work with this
/// hosting view — use `Button` instead.
class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}
