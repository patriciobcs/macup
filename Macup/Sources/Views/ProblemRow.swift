import SwiftUI

/// A manager that could not be checked: one plain sentence and the actions that help.
struct ProblemRow: View {
    @Environment(UpdateStore.self) private var store
    let report: ManagerReport
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(compact ? .caption : .body)
            Text(report.friendlyMessage).font(compact ? .caption : .callout).lineLimit(2)
            Spacer(minLength: 4)
            Menu {
                Button("Retry") { Task { await store.scan(managers: [report.manager]) } }
                Button("Copy Details") { Support.copy(details) }
                Button("Report on GitHub…") { NSWorkspace.shared.open(Support.issueURL(title: title, body: details)) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More actions")
            .help("Retry, copy details, or report")
        }
        .help(report.message.isEmpty ? report.friendlyMessage : report.message)
        .padding(.horizontal, compact ? 14 : 12).padding(.vertical, compact ? 4 : 6)
    }

    private var title: String { "\(report.manager.title): could not check for updates" }
    private var details: String { Support.details(title: title, manager: report.manager, raw: report.message) }
}

/// One line for the whole scan when the network is unavailable; not something to report.
struct OfflineRow: View {
    var compact = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash").foregroundStyle(.secondary).font(compact ? .caption : .body)
            Text("No internet connection. Showing the last results.").font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, compact ? 14 : 12).padding(.vertical, compact ? 4 : 6)
    }
}
