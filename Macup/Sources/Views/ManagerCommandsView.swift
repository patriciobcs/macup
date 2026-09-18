import SwiftUI

/// The commands MacUp runs for one manager, shown so they can be read and changed.
struct ManagerCommandsView: View {
    @Environment(UpdateStore.self) private var store
    @Environment(Preferences.self) private var settings
    let manager: Manager
    @State private var catalog = CommandCatalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = manager.notEditableReason {
                Label(reason, systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Every phase is listed, whether or not there is a command behind it: a row that simply
            // vanished would leave the reason to guesswork.
            ForEach(CommandPhase.appPhases) { phase in
                if catalog.book[manager].defaults[phase] != nil {
                    CommandField(manager: manager, phase: phase)
                } else if let reason = manager.noCommandReason(phase) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.title).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(reason).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            let used = CommandPlaceholder.used(
                in: CommandPhase.appPhases.compactMap { catalog.command($0, manager, settings: settings) }
                    .filter { !$0.isEmpty })
            if !used.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(used, id: \.name) { placeholder in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("{\(placeholder.name)}").font(.caption2.monospaced())
                            Text(placeholder.meaning).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Update All uses the package update command for eligible packages.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
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
        // Wrapped so the Form sees one block: left to itself it takes the title for a row label, puts
        // the field in a trailing column and sizes it to its text, which is how a command ends up
        // squeezed against the right edge.
        HStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(phase.title).font(.caption.bold())
                if changed {
                    Text("changed")
                        .font(.caption2).foregroundStyle(.orange)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                }
                Spacer()
                if editable, changed {
                    Button("Reset") {
                        catalog.setCommand("", phase, manager, settings: settings)
                        text = catalog.command(phase, manager, settings: settings)
                        result = nil
                    }
                    .controlSize(.small)
                }
                if editable, phase == .check {
                    Button(testing ? "Testing…" : "Test") { Task { await test() } }
                        .controlSize(.small).disabled(testing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if editable {
                // One line, not a growing field: a command is a command line, and a field that resizes
                // itself as the text changes can put AppKit into a constraint loop.
                TextField("", text: $text)
                    .font(.caption.monospaced()).textFieldStyle(.roundedBorder)
                    // labelsHidden, or the Form keeps a label column for the field's empty label and
                    // puts the field itself in the trailing column, sized to its text — which is how a
                    // command ends up squeezed against the right edge instead of filling the row.
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            }
            if let note = phase.note, editable, changed {
                Text(note).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let result {
                Text(result).font(.caption2).foregroundStyle(result.hasPrefix("✓") ? .green : .orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        result = CommandTest.message(for: scan, manager: manager)
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
