import AppKit
import Testing
@testable import Ghostty

@Suite
struct SidebarTabManagerTests {
    @MainActor
    @Test
    func invalidationDropsWindowReferencesAndPreventsRefresh() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let manager = SidebarTabManager(window: window)

        #expect(manager.tabs.count == 1)

        manager.invalidate()
        manager.refresh()

        #expect(manager.isInvalidated)
        #expect(manager.tabs.isEmpty)
        #expect(manager.projectGroups.isEmpty)
        #expect(manager.selectedTabID == nil)
    }
}
