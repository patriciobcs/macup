import AppKit
import SwiftUI

struct InstallationsView: View {
    @Environment(UpdateStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var onlyNeedsReview = false

    private var items: [InstalledItem] {
        InstallationList.filtered(store.installations, query: query, needsReview: onlyNeedsReview)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Installations").font(.title2.weight(.semibold))
                Text("\(store.installations.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { Task { await store.scan() } }.disabled(store.isScanning)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            HStack {
                TextField("Search apps, tools, owners or paths", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Needs review", isOn: $onlyNeedsReview).toggleStyle(.checkbox)
            }.padding(.horizontal).padding(.bottom, 10)
            Divider()
            if items.isEmpty {
                ContentUnavailableView(
                    store.isScanning ? "Checking installations…" : "No matching installations",
                    systemImage: "square.stack.3d.up",
                    description: Text("Check now to discover installed apps, runtimes and command-line tools."))
            } else {
                List(items) { item in InstallationRow(item: item) }
                    .listStyle(.inset)
            }
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 480, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

enum InstallationList {
    static func filtered(_ items: [InstalledItem], query: String, needsReview: Bool) -> [InstalledItem] {
        items.filter { item in
            let match =
                query.isEmpty
                || [item.name, item.reference.path, item.reference.owner, item.note]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            let review =
                item.state == .orphaned || item.state == .inactive || (item.latest == nil && item.state != .managed)
            return match && (!needsReview || review)
        }.sorted {
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.reference.path < $1.reference.path
        }
    }
}

private struct InstallationRow: View {
    @Environment(UpdateStore.self) private var store
    let item: InstalledItem

    private var canAct: Bool {
        guard let action = item.reference.update else { return false }
        return action.isHandoff || item.latest == nil || item.updateAvailable == true
            || item.latest.map { Version.isNewer($0, than: item.version) } == true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.manager.symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).font(.body.weight(.medium))
                    Text(item.version).foregroundStyle(.secondary)
                    if let latest = item.latest,
                        item.updateAvailable == true || Version.isNewer(latest, than: item.version)
                    {
                        Text("→ \(latest)").foregroundStyle(.secondary)
                    }
                    Text(item.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.reference.path).font(.caption.monospaced()).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
                Text(item.note.isEmpty ? "Managed by \(item.reference.owner)" : item.note)
                    .font(.caption).foregroundStyle(.secondary)
                if item.latest == nil && item.state != .managed {
                    Text("Latest version unknown").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.isUpgrading(item.package) {
                ProgressView().controlSize(.small)
            } else if canAct, let action = item.reference.update {
                Button(action.title) { Task { await store.upgrade(item.package) } }.controlSize(.small)
            }
            if item.reference.remove != nil {
                Button("Remove…") {
                    if UpdateStore.confirmRemoval(of: item.package) { Task { await store.remove(item.package) } }
                }.controlSize(.small).disabled(store.isUpgrading(item.package))
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Copy Path") { Support.copy(item.reference.path) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.reference.path)])
            }
            if let action = item.reference.update, action.kind != .nodePatch {
                Button("Copy Update Command") { Support.copy(InstallationActions.commandLine(action)) }
            }
        }
    }
}
