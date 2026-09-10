import SwiftUI
import AppKit

/// Renders the app's own views with sample data into PNG files, for the website and README.
/// Triggered by launching with MACUP_SCREENSHOTS=<output directory>; the app exits when done.
@MainActor
enum Screenshots {
    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["MACUP_SCREENSHOTS"], !dir.isEmpty else { return false }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = UpdateStore.fixture()
        let settings = Preferences.shared
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            capture(MenuBarPanel().environment(store).environment(settings),
                    size: nil, dark: dark, to: url.appendingPathComponent("menubar-\(suffix).png"))
            // The real window uses an AppKit split view, which needs on-screen layout; the same two panes side by side.
            capture(HStack(spacing: 0) {
                        UpdatesView().frame(width: 430)
                        Divider()
                        RightPane()
                    }.environment(store).environment(settings),
                    size: CGSize(width: 900, height: 540), dark: dark, to: url.appendingPathComponent("window-\(suffix).png"))
            capture(SettingsView().environment(store).environment(settings),
                    size: CGSize(width: 520, height: 700), dark: dark, to: url.appendingPathComponent("settings-\(suffix).png"))
        }
        NSApp.terminate(nil)
        return true
    }

    /// Hosts the view in a real (offscreen) window and caches its display: unlike ImageRenderer this draws
    /// AppKit-backed controls such as buttons, forms and split views.
    private static func capture<V: View>(_ view: V, size: CGSize?, dark: Bool, to url: URL) {
        // The background is drawn by the view itself so it resolves in the view's appearance (light or dark).
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: size == nil ? .underPageBackgroundColor : .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? CGSize(width: 320, height: 600)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isOpaque = true
        window.contentView = hosting
        if size == nil {
            hosting.layoutSubtreeIfNeeded()
            let fit = hosting.fittingSize
            window.setContentSize(CGSize(width: 320, height: max(fit.height, 200)))
        }
        window.orderBack(nil)   // real layout pass; the window stays behind everything and closes right away
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { window.close(); return }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        window.close()
    }
}

extension UpdateStore {
    /// A store filled with representative packages, no scanning, for screenshots and previews.
    static func fixture() -> UpdateStore {
        let store = UpdateStore(persist: false)
        let now = Date()
        func pkg(_ m: Manager, _ name: String, _ from: String, _ to: String, kind: String = "formula",
                 releasedDaysAgo: Double, updatedDaysAgo: Double, advisories: [String] = []) -> OutdatedPackage {
            var p = OutdatedPackage(manager: m, name: name, installed: from, latest: to, kind: kind, extra: "")
            p.releaseDate = now.addingTimeInterval(-releasedDaysAgo * 86_400); p.dateSource = .registry
            p.updatedAt = now.addingTimeInterval(-updatedDaysAgo * 86_400); p.advisories = advisories
            return p
        }
        store.loadFixture(
            reports: Manager.allCases.map { ManagerReport(manager: $0, status: [.macos, .brew, .npm, .bun, .pip, .uv, .cargo, .rustup, .gem, .tools].contains($0) ? .ok : .missing, message: "") },
            packages: [
                pkg(.brew, "ghostty", "1.2.3", "1.3.1", kind: "cask", releasedDaysAgo: 6, updatedDaysAgo: 40),
                pkg(.brew, "jq", "1.7.1", "1.8.2", releasedDaysAgo: 12, updatedDaysAgo: 120),
                pkg(.npm, "npm", "10.9.7", "12.0.2", kind: "global", releasedDaysAgo: 30, updatedDaysAgo: 200),
                pkg(.npm, "corepack", "0.34.6", "0.36.0", kind: "global", releasedDaysAgo: 9, updatedDaysAgo: 200),
                pkg(.bun, "wrangler", "4.91.0", "4.129.0", kind: "global", releasedDaysAgo: 2, updatedDaysAgo: 65),
                pkg(.uv, "modal", "1.5.4", "1.5.5", kind: "tool", releasedDaysAgo: 8, updatedDaysAgo: 18),
                pkg(.cargo, "cargo-nextest", "0.9.67", "0.9.143", kind: "crate", releasedDaysAgo: 35, updatedDaysAgo: 400,
                    advisories: ["RUSTSEC-2026-0012"]),
                pkg(.rustup, "stable-aarch64-apple-darwin", "1.93.0", "1.98.1", kind: "toolchain", releasedDaysAgo: 5, updatedDaysAgo: 230),
                pkg(.tools, "uv", "0.7.8", "0.12.10", kind: "tool", releasedDaysAgo: 4, updatedDaysAgo: 470),
                pkg(.npm, "happy", "1.1.8", "1.2.3", kind: "global", releasedDaysAgo: 0.4, updatedDaysAgo: 3),
            ],
            log: "── Homebrew: jq ──\n$ brew upgrade -- jq\n==> Upgrading jq 1.7.1 -> 1.8.2\n🍺  /opt/homebrew/Cellar/jq/1.8.2: 21 files, 1.4MB\n✓ done\n"
        )
        return store
    }
}
