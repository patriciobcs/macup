import SwiftUI
import XCTest

/// Draws a view offscreen and forces a layout and display pass, the way the screenshot renderer does.
/// Shared so any test can check that a view builds and draws in a given state.
@MainActor
func renderOffscreen<V: View>(
    _ view: V, size: CGSize = CGSize(width: 900, height: 640),
    file: StaticString = #filePath, line: UInt = #line
) {
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isOpaque = true
    // A window made in code is released when closed, which over-releases it under ARC.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderBack(nil)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    defer { window.close() }
    guard let content = window.contentView,
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
    else { return XCTFail("the view produced nothing to draw", file: file, line: line) }
    content.cacheDisplay(in: content.bounds, to: rep)
    XCTAssertGreaterThan(rep.pixelsHigh, 0, "the view drew no pixels", file: file, line: line)
}
