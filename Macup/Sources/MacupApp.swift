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
            MenuBarLabel(count: store.badgeCount, showCount: settings.showMenuBarCount)
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

/// Opens the setup window on the first launch. Menu bar apps have no main window to hang this on.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Screenshots.runIfRequested() { return }
        if !Preferences.shared.hasOnboarded {
            OnboardingWindow.show(store: UpdateStore.shared, settings: Preferences.shared)
        }
    }
}

struct MenuBarLabel: View {
    let count: Int
    let showCount: Bool

    var body: some View {
        HStack(spacing: 3) {
            // Outline when everything is current, filled when updates are waiting.
            Image(systemName: count > 0 ? "arrow.up.circle.fill" : "arrow.up.circle")
            if count > 0 && showCount {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .help(count == 0 ? "Everything is up to date" : "\(count) updates ready")
    }
}
