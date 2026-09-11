import SwiftUI

@main
struct MacupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = UpdateStore.shared
    @State private var settings = Preferences.shared

    init() {
        // Screenshot mode renders fixtures and quits; a real scan would only slow that down.
        if ProcessInfo.processInfo.environment["MACUP_SCREENSHOTS"] == nil { UpdateStore.shared.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(store)
                .environment(settings)
        } label: {
            MenuBarLabel(updates: store.badgeCount, showCount: settings.showMenuBarCount)
        }
        .menuBarExtraStyle(.window)

        Window("MacUp", id: "main") {
            MainWindowView()
                .environment(store)
                .environment(settings)
        }
        .defaultSize(width: 760, height: 520)

        Settings {
            SettingsView()
                .environment(store)
                .environment(settings)
        }
    }
}

/// Opens the setup window on the first launch, and switches the app between menu-bar-only and regular
/// mode: a menu bar agent has no application menu, so while a window is open MacUp becomes a regular app
/// (name and menus in the menu bar, Dock icon) and returns to the menu bar when the last window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Screenshots.runIfRequested() { return }
        DockIcon.followSystemAppearance()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(windowChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.willCloseNotification, object: nil)
        if !Preferences.shared.hasOnboarded {
            OnboardingWindow.show(store: UpdateStore.shared, settings: Preferences.shared)
        }
    }

    @objc private func windowChanged(_ note: Notification) {
        // Decide after the closing window is gone from the list.
        DispatchQueue.main.async {
            let open = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
            let wanted: NSApplication.ActivationPolicy = open ? .regular : .accessory
            if NSApp.activationPolicy() != wanted {
                NSApp.setActivationPolicy(wanted)
                if open { NSApp.activate(ignoringOtherApps: true) }
                DockIcon.refresh()
            }
        }
    }
}

struct MenuBarLabel: View {
    let updates: Int
    let showCount: Bool

    var body: some View {
        HStack(spacing: 3) {
            // Outline when everything is current, filled when updates are waiting.
            // An NSImage template symbol keeps the exact point size; SwiftUI's Image scales status item glyphs down.
            Image(nsImage: Self.symbol(updates > 0 ? "arrow.up.circle.fill" : "arrow.up.circle"))
            if updates > 0 && showCount {
                Text("\(updates)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .help(updates == 0 ? "Everything is up to date" : "\(updates) updates ready")
    }

    private static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
        image.isTemplate = true
        return image
    }
}
