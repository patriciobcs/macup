import SwiftUI

struct SettingsView: View {
    @Environment(Preferences.self) private var settings
    @Environment(UpdateStore.self) private var store

    private let ageChoices: [(String, Double)] = [
        ("Immediately", 0), ("1 hour", 1), ("4 hours", 4), ("12 hours", 12), ("1 day", 24), ("3 days", 72), ("1 week", 168)
    ]
    private let intervalChoices: [(String, Double)] = [
        ("Every hour", 1), ("Every 3 hours", 3), ("Every 6 hours", 6), ("Every 12 hours", 12), ("Once a day", 24)
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
                Text("Waiting before installing a fresh release gives maintainers time to pull broken or compromised versions. Security fixes for a version you have installed use the shorter delay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                LabeledContent("Setup") {
                    Button("Show Setup…") { OnboardingWindow.show(store: store, settings: settings) }.controlSize(.small)
                }
                LabeledContent("MacUp \(store.appVersion)") {
                    if AppUpdater.shared.source == .homebrew {
                        HStack(spacing: 8) {
                            Text("Installed with Homebrew").font(.caption).foregroundStyle(.secondary)
                            Button("Check Now") { Task { await store.scan(managers: [.brew]) } }.controlSize(.small)
                        }
                    } else {
                        Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }.controlSize(.small)
                    }
                }
            }
            Section("Package managers") {
                ForEach(Manager.allCases) { manager in
                    let report = store.reports.first { $0.manager == manager }
                    if manager == .mas && report?.status == .missing {
                        ManagerSetupRow(manager: manager)
                    } else {
                    Toggle(isOn: Binding(
                        get: { !settings.disabledManagers.contains(manager) },
                        set: { on in if on { settings.disabledManagers.remove(manager) } else { settings.disabledManagers.insert(manager) } }
                    )) {
                        HStack {
                            Label(manager.title, systemImage: manager.symbol)
                            Spacer()
                            Text(statusText(report)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(report?.status == .missing)
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
