import AppKit
import XCTest

@testable import Macup

/// macOS leaves Dock icons light in Dark Mode unless the user picks a dark icon style, so the app
/// swaps its own. These tests run against the real NSApplication the tests are hosted in.
@MainActor
final class DockIconTests: XCTestCase {
    private var original: NSImage?
    private var originalAppearance: NSAppearance?

    override func setUp() {
        original = NSApp.applicationIconImage
        originalAppearance = NSApp.appearance
    }

    override func tearDown() {
        NSApp.applicationIconImage = original
        NSApp.appearance = originalAppearance
    }

    func testBothRenditionsAreBundled() {
        XCTAssertNotNil(DockIcon.icon("AppIconDefault"), "the light rendition is missing from the bundle")
        XCTAssertNotNil(DockIcon.icon("AppIconDark"), "the dark rendition is missing from the bundle")
        XCTAssertNil(DockIcon.icon("AppIconNonexistent"))
    }

    /// Brightness of the icon's background: a point inside the rounded square, clear of the glyph.
    /// NSApp hands back a re-composited image, so the pixels are what can be compared, not the bytes.
    private func backgroundBrightness(_ image: NSImage?) -> CGFloat {
        guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let color = rep.colorAt(x: rep.pixelsWide / 6, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
        else { return -1 }
        return color.brightnessComponent
    }

    func testTheDockIconMatchesTheCurrentAppearance() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        DockIcon.followSystemAppearance()
        let dark = backgroundBrightness(NSApp.applicationIconImage)
        XCTAssertLessThan(dark, 0.3, "dark appearance must put a dark background in the Dock")

        NSApp.appearance = NSAppearance(named: .aqua)
        DockIcon.followSystemAppearance()
        let light = backgroundBrightness(NSApp.applicationIconImage)
        XCTAssertGreaterThan(light, 0.7, "light appearance must put a light background in the Dock")
    }

    func testTheIconSurvivesBecomingARegularApp() {
        // MacUp launches as a menu bar agent with no Dock tile and only becomes a regular app when a
        // window opens, which is when the Dock builds the tile.
        let policy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(policy) }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.accessory)
        DockIcon.followSystemAppearance()
        NSApp.setActivationPolicy(.regular)
        DockIcon.refresh()
        XCTAssertLessThan(
            backgroundBrightness(NSApp.applicationIconImage), 0.3,
            "the dark icon must still be in place once the Dock tile exists")
    }

    func testTheIconIsInsetOntoTheStandardGrid() throws {
        // Without the margin the Dock draws MacUp larger than every neighbouring icon.
        let raw = try XCTUnwrap(DockIcon.icon("AppIconDark"))
        let placed = DockIcon.onIconGrid(raw)
        XCTAssertEqual(placed.size, raw.size, "the canvas keeps its size; only the artwork shrinks")

        let edge = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(placed.tiffRepresentation)))
        let mid = edge.pixelsHigh / 2
        XCTAssertEqual(
            edge.colorAt(x: edge.pixelsWide / 40, y: mid)?.alphaComponent, 0,
            "the outer margin must be empty")
        XCTAssertEqual(
            edge.colorAt(x: edge.pixelsWide / 2, y: mid)?.alphaComponent, 1, "the icon itself must still be drawn")
    }

    func testTheIconCastsAShadowIntoTheMargin() throws {
        // Every system icon fills its margin with a shadow; without one MacUp reads lighter than its
        // neighbours even at the right size.
        let placed = DockIcon.onIconGrid(try XCTUnwrap(DockIcon.icon("AppIconDark")))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(placed.tiffRepresentation)))
        let margin = Int(Double(rep.pixelsWide) * 0.09)  // inside the margin, outside the body
        let alpha = try XCTUnwrap(rep.colorAt(x: margin, y: rep.pixelsHigh / 2)?.alphaComponent)
        XCTAssertGreaterThan(alpha, 0, "the margin should carry the shadow")
        XCTAssertLessThan(alpha, 1, "the margin is a shadow, not the icon body")
    }

    func testTheTwoRenditionsAreActuallyDifferentImages() {
        let light = backgroundBrightness(DockIcon.icon("AppIconDefault"))
        let dark = backgroundBrightness(DockIcon.icon("AppIconDark"))
        XCTAssertGreaterThan(light - dark, 0.5, "the two exports must not be the same rendition")
    }
}
