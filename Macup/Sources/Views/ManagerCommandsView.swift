import SwiftUI

/// The commands MacUp runs for one manager, shown so they can be read and changed.
struct ManagerCommandsView: View {
    @Environment(UpdateStore.self) private var store
    @Environment(Preferences.self) private var settings
    let manager: Manager
    @State private var catalog = CommandCatalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reason = manager.notEditableReason {
                Label(reason, systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            let phases = catalog.book[manager].phases
            if phases.isEmpty {
                Text("MacUp checks this one by looking at the files it installed, rather than by running a command.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(phases) { phase in
                CommandField(manager: manager, phase: phase)
            }
        }
        .padding(.vertical, 4)
        .task { await catalog.loadIfNeeded() }
    }
}

/// One command: what runs, and what the user would rather run.
private struct CommandField: View {
    @Environment(UpdateStore.self) private var store
    @Environment(Preferences.self) private var settings
    let manager: Manager
    let phase: CommandPhase

    @State private var catalog = CommandCatalog.shared
    @State private var text = ""
    @State private var testing = false
    @State private var result: String?

    private var editable: Bool { manager.notEditableReason == nil }
    private var changed: Bool { catalog.isChanged(phase, manager, settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(phase.title).font(.caption.bold())
                if changed { Text("changed").font(.caption2).foregroundStyle(.orange) }
                Spacer()
                if editable, phase == .check {
                    Button(testing ? "Testing…" : "Test") { Task { await test() } }
                        .controlSize(.small).disabled(testing)
                }
                if editable, changed {
                    Button("Reset") {
                        catalog.setCommand("", phase, manager, settings: settings)
                        text = catalog.command(phase, manager, settings: settings)
                        result = nil
                    }
                    .controlSize(.small)
                }
            }
            if editable {
                // One line, not a growing field: a command is a command line, and a field that resizes
                // itself as the text changes can put AppKit into a constraint loop.
                TextField("", text: $text)
                    .font(.caption.monospaced()).textFieldStyle(.roundedBorder)
                    // Saved as it is typed rather than on the way out: writing to preferences from
                    // onDisappear changes an observed object while the window is being torn down,
                    // which invalidates views in the middle of a layout pass.
                    .onChange(of: text) { _, _ in
                        result = nil
                        save()
                    }
            } else {
                Text(catalog.command(phase, manager, settings: settings))
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
            }
            if let note = phase.note, editable {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            if let result {
                Text(result).font(.caption2).foregroundStyle(result.hasPrefix("✓") ? .green : .orange)
            }
        }
        .onAppear { text = catalog.command(phase, manager, settings: settings) }
    }

    private func save() { catalog.setCommand(text, phase, manager, settings: settings) }

    /// Runs the command as the scan would and says what came back. A command can succeed and still be
    /// useless — if it prints something the parser does not recognise, nothing is found and the
    /// manager quietly looks up to date, which is the failure this button exists to catch.
    private func test() async {
        save()
        testing = true
        defer { testing = false }
        let scan = await ScriptRunner.testCheck(
            manager: manager, command: text, brewGreedy: settings.brewGreedy)
        let report = scan.reports.first { $0.manager == manager }
        if let report, report.status == .error {
            result = "✗ \(report.message)"
        } else if scan.packages.isEmpty {
            result =
                "✓ ran, but nothing was understood. Either there is nothing to update, or the output is "
                + "not in the shape MacUp reads."
        } else {
            result = "✓ understood \(scan.packages.count) package\(scan.packages.count == 1 ? "" : "s")"
        }
    }
}

/// The self-installed tools, split into the ones on this Mac and the ones that are not.
struct SelfInstalledToolsList: View {
    @Environment(UpdateStore.self) private var store
    @State private var showMissing = false

    private var here: [ToolReport] { store.tools.filter { $0.presence == .found } }
    private var elsewhere: [ToolReport] { store.tools.filter { $0.presence != .found } }

    var body: some View {
        if store.tools.isEmpty {
            Text("Not looked for yet.").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(here) { tool in
                    ToolRow(tool: tool)
                }
                if here.isEmpty {
                    Text("None on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
                if !elsewhere.isEmpty {
                    DisclosureGroup(isExpanded: $showMissing) {
                        ForEach(elsewhere) { tool in
                            ToolRow(tool: tool)
                        }
                    } label: {
                        Text("\(elsewhere.count) not installed here").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct ToolRow: View {
    let tool: ToolReport

    var body: some View {
        HStack {
            Text(tool.name).font(.caption)
            Spacer()
            Text(tool.statusText).font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(tool.presence == .found ? .primary : .secondary)
    }
}

/// One manager in Settings: whether it is used at all, and what it runs when it is.
struct ManagerSettingsRow: View {
    @Environment(Preferences.self) private var settings
    let manager: Manager
    let status: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if manager == .tools {
                SelfInstalledToolsList()
                Divider().padding(.vertical, 4)
            }
            ManagerCommandsView(manager: manager)
        } label: {
            Toggle(
                isOn: Binding(
                    get: { !settings.disabledManagers.contains(manager) },
                    set: { on in
                        if on {
                            settings.disabledManagers.remove(manager)
                        } else {
                            settings.disabledManagers.insert(manager)
                        }
                    }
                )
            ) {
                HStack {
                    Label(manager.title, systemImage: manager.symbol)
                    Spacer()
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
