import SwiftUI

struct SettingsView: View {
    @State private var showAbsent = false
    @Environment(Preferences.self) private var settings
    @Environment(UpdateStore.self) private var store

    private let ageChoices: [(String, Double)] = [
        ("Immediately", 0), ("1 hour", 1), ("4 hours", 4), ("12 hours", 12), ("1 day", 24), ("3 days", 72),
        ("1 week", 168),
    ]
    private let autoChoices: [(String, Double)] = [
        ("Once an hour", 1), ("Every 6 hours", 6), ("Once a day", 24), ("Twice a week", 84), ("Once a week", 168),
    ]
    private let intervalChoices: [(String, Double)] = [
        ("Every hour", 1), ("Every 3 hours", 3), ("Every 6 hours", 6), ("Every 12 hours", 12), ("Once a day", 24),
    ]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Timing") {
                Picker("Show updates released at least", selection: $settings.minAgeHours) {
                    ForEach(ageChoices, id: \.1) { Text($0.0 + ($0.1 == 0 ? "" : " ago")).tag($0.1) }
                }
                Picker("Show security updates released at least", selection: $settings.securityMinAgeHours) {
                    ForEach(ageChoices, id: \.1) { Text($0.0 + ($0.1 == 0 ? "" : " ago")).tag($0.1) }
                }
                Picker("Check for updates", selection: $settings.checkIntervalHours) {
                    ForEach(intervalChoices, id: \.1) { Text($0.0).tag($0.1) }
                }
                Toggle("Install ready updates automatically", isOn: $settings.autoUpdate)
                if settings.autoUpdate {
                    Picker("Install at most", selection: $settings.autoUpdateIntervalHours) {
                        ForEach(autoChoices, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    Text(
                        "Only updates that have passed the minimum age above are installed, and macOS updates are left alone because they need a restart. Anything that asks for an administrator password is skipped."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Text(
                    "Waiting before installing a fresh release gives maintainers time to pull broken or compromised versions. Security fixes for a version you have installed use the shorter delay."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Notify when updates become ready", isOn: $settings.notificationsEnabled)
                Toggle("Show the number of updates in the menu bar", isOn: $settings.showMenuBarCount)
                Toggle("Include Homebrew apps that update themselves", isOn: $settings.brewGreedy)
                Toggle(isOn: $settings.hideSystemPackages) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide packages that belong to macOS")
                        Text(
                            "System Ruby gems, Xcode's Python packages and other root-owned installs. macOS manages these itself and changing them needs an administrator password."
                                + (store.hiddenSystemCount > 0 ? " Currently hiding \(store.hiddenSystemCount)." : "")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Setup") {
                    Button("Show Setup…") { OnboardingWindow.show(store: store, settings: settings) }.controlSize(
                        .small)
                }
                LabeledContent("MacUp \(store.appVersion)") {
                    // The store decides what updating MacUp means for this copy; asking AppUpdater here
                    // would be a second answer to the same question.
                    if store.installSource == .homebrew {
                        HStack(spacing: 8) {
                            Text("Installed with Homebrew").font(.caption).foregroundStyle(.secondary)
                            Button("Check Now") { Task { await store.scan(managers: [.brew]) } }.controlSize(.small)
                        }
                    } else {
                        Button("Check for Updates…") { Task { await store.updateSelf() } }.controlSize(.small)
                    }
                }
            }
            Section("Package managers") {
                ForEach(present) { manager in
                    ManagerSettingsRow(manager: manager, status: statusText(report(for: manager)))
                }
                if !absent.isEmpty {
                    DisclosureGroup(isExpanded: $showAbsent) {
                        ForEach(absent) { manager in
                            if manager == .mas {
                                ManagerSetupRow(manager: manager)
                            } else {
                                HStack {
                                    Label(manager.title, systemImage: manager.symbol)
                                    Spacer()
                                    Text(statusText(report(for: manager))).font(.caption)
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        Text("^[\(absent.count) manager](inflect: true) not installed").foregroundStyle(.secondary)
                    }
                }
            }
            if !settings.ignoredPackages.isEmpty {
                Section("Ignored packages") {
                    ForEach(settings.ignoredPackages.sorted(), id: \.self) { id in
                        HStack {
                            Text(id.replacingOccurrences(of: ":", with: " · "))
                            Spacer()
                            Button("Show again") { store.unignore(id: id) }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: settings.disabledManagers) { _, _ in Task { await store.scan() } }
        .onChange(of: settings.brewGreedy) { _, _ in Task { await store.scan(managers: [.brew]) } }
        .onChange(of: settings.checkIntervalHours) { _, _ in store.restartSchedule() }
    }

    private func report(for manager: Manager) -> ManagerReport? {
        store.reports.first { $0.manager == manager }
    }

    /// Managers found on this Mac. Anything not scanned yet counts as present, so the list does not
    /// start out claiming that nothing is installed.
    private var present: [Manager] {
        Manager.allCases.filter { report(for: $0)?.status != .missing }
    }
    private var absent: [Manager] {
        Manager.allCases.filter { report(for: $0)?.status == .missing }
    }

    private func manager(_ r: ManagerReport) -> Manager { r.manager }

    private func statusText(_ r: ManagerReport?) -> String {
        guard let r else { return "" }
        switch r.status {
        case .ok: return r.needsAdmin ? "found · needs admin password to change" : "found"
        case .missing: return manager(r) == .mas ? "needs the mas tool" : "not installed"
        case .error: return "error"
        case .skipped: return r.message
        }
    }
}
