import SwiftUI
import XCTest

/// Draws a view offscreen and forces a layout and display pass, the way the screenshot renderer does,
/// then hands back the pixels. Shared so any test can check what a view actually draws.
@MainActor
func renderBitmap<V: View>(
    _ view: V, size: CGSize = CGSize(width: 900, height: 640), settle: TimeInterval = 0.2
) -> NSBitmapImageRep? {
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isOpaque = true
    // A window made in code is released when closed, which over-releases it under ARC.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderBack(nil)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(settle))
    defer { window.close() }
    guard let content = window.contentView,
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
    else { return nil }
    content.cacheDisplay(in: content.bounds, to: rep)
    return rep
}

/// Draws a view offscreen and fails the test if it produced nothing.
@MainActor
func renderOffscreen<V: View>(
    _ view: V, size: CGSize = CGSize(width: 900, height: 640),
    file: StaticString = #filePath, line: UInt = #line
) {
    guard let rep = renderBitmap(view, size: size) else {
        return XCTFail("the view produced nothing to draw", file: file, line: line)
    }
    XCTAssertGreaterThan(rep.pixelsHigh, 0, "the view drew no pixels", file: file, line: line)
}
