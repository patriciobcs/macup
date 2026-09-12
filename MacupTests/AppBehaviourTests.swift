import AppKit
import SwiftUI
import XCTest

@testable import Macup

/// Behaviour of the app shell itself: the menu bar label, the clipboard, and the switch between a
/// menu bar agent and a regular app. These run against the real NSApplication hosting the tests.
@MainActor
final class AppBehaviourTests: XCTestCase {
    func testCopyingDetailsPutsThemOnThePasteboard() {
        let board = NSPasteboard.general
        let previous = board.string(forType: .string)
        defer {
            board.clearContents()
            if let previous { board.setString(previous, forType: .string) }
        }

        let details = Support.details(title: "Homebrew failed", manager: .brew, raw: "Error: no such keg")
        Support.copy(details)

        XCTAssertEqual(board.string(forType: .string), details, "Copy Details must paste the whole report")
        XCTAssertTrue(board.string(forType: .string)?.contains("Manager: Homebrew (brew)") == true)
    }

    func testTheMenuBarLabelShowsAndHidesTheCount() {
        // With updates waiting the glyph is filled and the number sits beside it; with none, neither.
        renderOffscreen(MenuBarLabel(updates: 3, showCount: true), size: CGSize(width: 60, height: 24))
        renderOffscreen(MenuBarLabel(updates: 3, showCount: false), size: CGSize(width: 40, height: 24))
        renderOffscreen(MenuBarLabel(updates: 0, showCount: true), size: CGSize(width: 40, height: 24))
    }

    /// MacUp is a menu bar agent with no Dock tile, and becomes a regular app only while a window is
    /// open, so it has an application menu. The delegate does that in response to window notifications.
    func testAWindowMakesItARegularAppAndClosingItReturnsToTheMenuBar() async throws {
        let original = NSApp.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            NSApp.setActivationPolicy(original)
        }

        NSApp.setActivationPolicy(.accessory)
        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(NSApp.activationPolicy(), .regular, "an open window gives MacUp a Dock tile and menus")

        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(NSApp.activationPolicy(), .accessory, "with the window gone it is a menu bar agent again")
    }
}
