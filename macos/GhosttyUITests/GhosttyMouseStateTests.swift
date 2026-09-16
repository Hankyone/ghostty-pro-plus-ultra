//
//  GhosttyMouseStateTests.swift
//  Ghostty
//
//  Created by Lukas on 19.03.2026.
//

import AppKit
import XCTest

final class GhosttyMouseStateTests: GhosttyCustomConfigCase {
    @MainActor func testRepeatedClicksSelectTextInClickedSplit() async throws {
        try updateConfig("""
        pane-keeper = false
        window-save-state = never
        confirm-close-surface = false
        focus-follows-mouse = false
        copy-on-select = false
        shell-integration = none
        command = /bin/zsh -f
        font-size = 16
        window-padding-x = 0
        window-padding-y = 0
        """)
        let app = try ghosttyApplication()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        let pasteboard = NSPasteboard.general
        let savedItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }

        func waitForText(_ text: String, in element: XCUIElement) {
            let predicate = NSPredicate(format: "value CONTAINS %@", text)
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        }

        waitForText("%", in: app.textViews.firstMatch)
        app.typeText("printf '\\033[2J\\033[HDECOY\\nTOP_MARKER alpha beta gamma\\n'\r")
        app.typeKey("d", modifierFlags: [.command, .shift])
        let top = app.groups["Top pane"].textViews.firstMatch
        let bottom = app.groups["Bottom pane"].textViews.firstMatch
        XCTAssertTrue(bottom.waitForExistence(timeout: 5))
        waitForText("%", in: bottom)
        app.typeText("printf '\\033[2J\\033[HDECOY\\nBOTTOM_MARKER delta epsilon zeta\\n'\r")
        // Require rendered output so echoed shell commands cannot satisfy setup.
        waitForText("DECOY\nTOP_MARKER", in: top)
        waitForText("DECOY\nBOTTOM_MARKER", in: bottom)

        for (pane, marker) in [(top, "TOP_MARKER"), (bottom, "BOTTOM_MARKER"),
                               (top, "TOP_MARKER"), (bottom, "BOTTOM_MARKER")] {
            // Separate double-click sequences so they cannot become a triple-click.
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
            let point = pane.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: 25, dy: 30))
            point.click() // Focus-only when switching panes.
            point.doubleClick()
            pasteboard.clearContents()
            app.typeKey("c", modifierFlags: .command)
            XCTAssertEqual(pasteboard.string(forType: .string), marker)
        }

        let start = top.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: 5, dy: 30))
        let end = bottom.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: 150, dy: 70))
        start.click()
        start.click(forDuration: 0.1, thenDragTo: end)
        pasteboard.clearContents()
        app.typeKey("c", modifierFlags: .command)
        let draggedText = pasteboard.string(forType: .string) ?? ""
        XCTAssertTrue(draggedText.contains("TOP_MARKER"))
        XCTAssertFalse(draggedText.contains("BOTTOM_MARKER"))

        // Releasing in another pane must end the original gesture cleanly.
        let bottomPoint = bottom.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: 25, dy: 30))
        bottomPoint.click()
        bottomPoint.doubleClick()
        pasteboard.clearContents()
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(pasteboard.string(forType: .string), "BOTTOM_MARKER")
    }

    // https://github.com/ghostty-org/ghostty/pull/11276
    @MainActor func testSelectionFocusChange() async throws {
        let app = XCUIApplication()
        app.activate()
        // Write dummy text to a temp file, cat it into the terminal, then clean up
        let lines = (1...200).map { "Line \($0): The quick brown fox jumps over the lazy dog. Lorem ipsum dolor sit amet, consectetur adipiscing elit." }
        let text = lines.joined(separator: "\n") + "\n"
        let tmpFile = NSTemporaryDirectory() + "ghostty_test_dummy.txt"
        try text.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        app.typeText("cat \(tmpFile)\r")
        app.menuItems["Command Palette"].firstMatch.click()

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()

        app.activate()

        app.buttons
            .containing(NSPredicate(format: "label CONTAINS[c] 'Clear Screen'"))
            .firstMatch
            .click()
        let surface = app.groups["Terminal pane"]
        surface
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: 20, dy: 10))
            .click()

        surface
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: 20, dy: surface.frame.height * 0.5))
            .hover()

        NSPasteboard.general.clearContents()
        app.typeKey("c", modifierFlags: .command)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), nil, "Moving mouse shouldn't select any texts")
    }

    @MainActor func testSearchFocusState() async throws {
        let app = try ghosttyApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "New window should appear")
        app.typeKey("f", modifierFlags: .command)

        let textfield = app.textFields.firstMatch
        XCTAssertTrue(textfield.waitForExistence(timeout: 5), "Search field should appear")
        app.typeText("a")

        XCTAssertTrue(textfield.stringValue == "a", "Search text should be `a`")

        textfield.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: textfield.frame.width * 0.5, dy: 0))
            .click()

        app.typeText("b")

        XCTAssertTrue(textfield.stringValue == "ab", "Search text should be `ab`")

        // resign
        app.typeKey(.escape, modifierFlags: [])

        // dismiss
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(textfield.waitForNonExistence(timeout: 5), "Search field should disappear")
    }
}

private extension XCUIElement {
    var stringValue: String? {
        (value as? String)
    }
}
