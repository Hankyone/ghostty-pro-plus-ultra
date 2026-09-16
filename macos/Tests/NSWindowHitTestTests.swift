import AppKit
import Testing
@testable import Ghostty

@MainActor
struct NSWindowHitTestTests {
    @Test(arguments: [false, true])
    func targetsClickedPane(flipped: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let content = HitTestContentView(flipped: flipped)
        window.contentView = content
        // Leave room for a sidebar, then use four panes to cover both split axes.
        let panes = [
            NSRect(x: 200, y: 0, width: 300, height: 300),
            NSRect(x: 500, y: 0, width: 300, height: 300),
            NSRect(x: 200, y: 300, width: 300, height: 300),
            NSRect(x: 500, y: 300, width: 300, height: 300),
        ].map { NSView(frame: $0) }
        panes.forEach(content.addSubview)

        for pane in panes {
            for offset in [NSPoint(x: 40, y: 60), NSPoint(x: 200, y: 220)] {
                let windowPoint = pane.convert(offset, to: nil)
                #expect(window.contentViewHitTest(at: windowPoint) === pane)
            }
        }

        // A search overlay must receive its own clicks even above a terminal.
        let overlay = NSView(frame: NSRect(x: 350, y: 40, width: 200, height: 40))
        content.addSubview(overlay)
        let overlayPoint = overlay.convert(NSPoint(x: 20, y: 20), to: nil)
        #expect(window.contentViewHitTest(at: overlayPoint) === overlay)
    }
}

private class HitTestContentView: NSView {
    private let usesFlippedCoordinates: Bool
    override var isFlipped: Bool { usesFlippedCoordinates }

    init(flipped: Bool) {
        self.usesFlippedCoordinates = flipped
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
