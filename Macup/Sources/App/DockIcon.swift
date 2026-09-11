import AppKit

/// Keeps the Dock icon in step with the system appearance.
///
/// The app icon carries a dark rendition, but macOS only draws it when the user picks a dark
/// "Icon & widget style" in System Settings; Dark Mode on its own leaves every Dock icon light.
/// Setting the icon ourselves makes MacUp match the rest of the interface, which is what a menu bar
/// app that is mostly invisible should do. Only the running app's Dock tile changes: Finder,
/// Spotlight and Launchpad still show the icon compiled into the bundle.
enum DockIcon {
    private static var observation: NSKeyValueObservation?

    /// Applies the right icon now, and again whenever the appearance changes or the app activates.
    static func followSystemAppearance() {
        apply()
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { apply() }
        }
        // Becoming a regular app builds the Dock tile from the bundle, dropping an icon set while
        // MacUp was still an agent, so the tile has to be painted again once it exists.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { apply() }
        }
    }

    /// Called after the activation policy changes, when the Dock has just created the tile.
    static func refresh() {
        apply()
        DispatchQueue.main.async { apply() }
    }

    /// Apple's macOS icon grid puts the rounded square on 824 points of a 1024-point canvas; the rest
    /// is margin and room for the shadow. Every icon in the Dock is drawn to the same tile, so an
    /// image without that margin simply looks bigger than its neighbours.
    private static let bodyScale: CGFloat = 824.0 / 1024.0
    /// The shadow that fills the margin. Measured off the system icons on a 1024-point canvas, theirs
    /// spreads 21 points sideways and sits 8 points low (13 above the body, 29 below); a 37-point blur
    /// reproduces that spread exactly. Without it the icon is the right size but reads lighter than
    /// everything beside it. The opacity is the one the icon itself asks for in icon.json.
    private static let shadowBlur: CGFloat = 37.0 / 1024.0
    private static let shadowDrop: CGFloat = 8.0 / 1024.0
    private static let shadowOpacity: CGFloat = 0.3

    private static func apply() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let image = icon(isDark ? "AppIconDark" : "AppIconDefault") else { return }
        NSApp.applicationIconImage = onIconGrid(image)
    }

    /// ictool exports the icon edge to edge, so the margin has to be put back.
    static func onIconGrid(_ image: NSImage) -> NSImage {
        let side = image.size.width
        let body = (side * bodyScale).rounded()
        let inset = ((side - body) / 2).rounded()
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowOpacity)
        shadow.shadowBlurRadius = side * shadowBlur
        shadow.shadowOffset = NSSize(width: 0, height: -side * shadowDrop)
        shadow.set()
        image.draw(
            in: NSRect(x: inset, y: inset, width: body, height: body), from: .zero, operation: .sourceOver,
            fraction: 1)
        canvas.unlockFocus()
        return canvas
    }

    /// The rendition exported from MacUp.icon at build time, alongside the scripts in Resources.
    static func icon(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "AppIcons")
        else { return nil }
        return NSImage(contentsOf: url)
    }
}
