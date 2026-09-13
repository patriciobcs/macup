import AppKit
import SwiftUI

/// First-run setup. Also reachable from Settings. Shows what MacUp discovered, offers optional tools,
/// and the two or three preferences worth deciding up front. Everything already works without it.
struct OnboardingView: View {
    @Environment(UpdateStore.self) private var store
    @Environment(Preferences.self) private var settings
    var close: () -> Void

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                Text("Welcome to MacUp").font(.title.weight(.semibold))
                Text("Keeps the tools you install from the command line up to date, from the menu bar.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 24).padding(.bottom, 12).padding(.horizontal, 24)

            Form {
                Section {
                    if store.isScanning {
                        HStack(spacing: 10) {
                            Text("Looking for package managers…").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(store.scanned.count) of \(store.scanTotal)")
                                .foregroundStyle(.secondary).font(.callout).monospacedDigit()
                            ProgressView(value: Double(store.scanned.count), total: Double(max(store.scanTotal, 1)))
                                .frame(width: 90)
                        }
                    }
                    ForEach(Manager.allCases) { manager in
                        ManagerSetupRow(manager: manager)
                    }
                } header: {
                    Text("Package managers on this Mac")
                } footer: {
                    Text("MacUp found these automatically. Nothing to configure.").font(.caption).foregroundStyle(
                        .secondary)
                }
                Section("Preferences") {
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    Toggle("Install ready updates automatically", isOn: $settings.autoUpdate)
                    Toggle("Notify me when updates are ready", isOn: $settings.notificationsEnabled)
                    Toggle("Hide packages that belong to macOS", isOn: $settings.hideSystemPackages)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Text("You can change all of this later in Settings.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
    }
}

/// One manager in the setup list: found, not installed, or installable with one click.
struct ManagerSetupRow: View {
    @Environment(UpdateStore.self) private var store
    let manager: Manager

    var body: some View {
        let report = store.reports.first { $0.manager == manager }
        HStack {
            Label(manager.title, systemImage: manager.symbol)
                .foregroundStyle(report?.status == .missing ? .secondary : .primary)
            Spacer()
            switch report?.status {
            case .ok:
                Label(
                    report?.needsAdmin == true ? "Found · needs password to change" : "Found",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green).labelStyle(.titleAndIcon).font(.callout)
            case .missing where manager == .mas:
                masInstall
            case .missing:
                Text("Not installed").foregroundStyle(.secondary).font(.callout)
            case .error, .skipped:
                Label(report?.message ?? "Error", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .font(.callout).lineLimit(1)
            case nil where store.isScanning:
                // Each manager is checked on its own, so a row waiting says so rather than sitting blank.
                ProgressView().controlSize(.small)
            case nil:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var masInstall: some View {
        if store.isInstalling(.mas) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary).font(.callout)
            }
        } else if store.reports.contains(where: { $0.manager == .brew && $0.status != .missing }) {
            HStack(spacing: 8) {
                Text("Needs the mas tool").foregroundStyle(.secondary).font(.callout)
                Button("Install") { Task { await store.installTool(.mas) } }.controlSize(.small)
            }
            .help("Runs `brew install mas`. mas lets MacUp list and update Mac App Store apps.")
        } else {
            HStack(spacing: 8) {
                Text("Needs Homebrew and mas").foregroundStyle(.secondary).font(.callout)
                Link("Get Homebrew", destination: URL(string: "https://brew.sh")!).controlSize(.small)
            }
        }
    }
}

/// AppKit-hosted window so it can be opened from app launch and from Settings alike.
@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?

    static func show(store: UpdateStore, settings: Preferences) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView { close() }.environment(store).environment(settings)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Welcome to MacUp"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        Preferences.shared.hasOnboarded = true
        window?.close()
        window = nil
    }
}
