import SwiftUI

/// The list of pending updates shown in the main window.
struct UpdatesView: View {
    @Environment(UpdateStore.self) private var store
    @Environment(Preferences.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if store.isScanning {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await store.scan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless).help("Check now").accessibilityLabel("Check now")
            }
        }
        .padding(.horizontal, 12).frame(height: 44)  // same height as the output pane's header so the dividers line up
    }

    private var title: String {
        if store.isScanning && store.packages.isEmpty { return "Checking for updates…" }
        let n = store.badgeCount
        if n == 0 { return "Everything is up to date" }
        return "\(n) update\(n == 1 ? "" : "s") ready"
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        let eligible = store.eligible
        let waiting = store.waiting
        if eligible.isEmpty && waiting.isEmpty && !store.isScanning {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Manager.allCases) { manager in
                        let items = eligible.filter { $0.manager == manager }
                        if !items.isEmpty { section(manager, items: items) }
                    }
                    if !waiting.isEmpty { waitingSection(waiting) }
                    if let err = store.scanError {
                        Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
                            .padding(12)
                    }
                    if store.isOffline { OfflineRow() }
                    ForEach(store.problems) { ProblemRow(report: $0) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal").font(.system(size: 28)).foregroundStyle(.green)
            Text("All \(store.discoveredManagers.count) package managers are up to date.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
    }

    private func section(_ manager: Manager, items: [OutdatedPackage]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("\(manager.title) · \(items.count)", systemImage: manager.symbol)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if store.needsAdmin(manager) {
                    Label("Asks for your password", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if items.count > 1 || manager == .rustup {
                    Button("Update all") { Task { await store.upgradeAll(manager) } }
                        .controlSize(.small).disabled(store.isUpgrading(manager) || store.isUpgradingAnything)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            ForEach(items) { PackageRow(pkg: $0, eligible: true) }
        }
    }

    private func waitingSection(_ items: [OutdatedPackage]) -> some View {
        DisclosureGroup {
            ForEach(items) { PackageRow(pkg: $0, eligible: false) }
        } label: {
            Text("\(items.count) newer release\(items.count == 1 ? "" : "s") waiting for the minimum age")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let last = store.lastScan {
                Text("Checked \(last, format: .relative(presentation: .named))").font(.caption).foregroundStyle(
                    .secondary)
            }
            Spacer()
            if store.updatableCount > 0 {
                Button(store.isUpgradingAnything ? "Updating…" : "Update all (\(store.updatableCount))") {
                    Task { await store.upgradeAllEligible() }
                }
                .controlSize(.small).buttonStyle(.borderedProminent).disabled(store.isUpgradingAnything)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct PackageRow: View {
    @Environment(UpdateStore.self) private var store
    let pkg: OutdatedPackage
    let eligible: Bool

    var body: some View {
        row.contextMenu {
            Button("Ignore \(pkg.name)") { store.ignore(pkg) }
            if pkg.manager.supportsRemoval {
                Button("Remove \(pkg.name)…") { confirmAndRemove() }
            }
            if let failure = store.failure(for: pkg) {
                Button("Copy Error") {
                    Support.copy(
                        Support.details(
                            title: "Update of \(pkg.name) failed", manager: pkg.manager, raw: failure,
                            version: store.version(of: pkg.manager)))
                }
                Button("Report on GitHub…") {
                    NSWorkspace.shared.open(
                        Support.issueURL(
                            title: "\(pkg.manager.title): update of \(pkg.name) failed",
                            body: Support.details(
                                title: "Update of \(pkg.name) failed", manager: pkg.manager, raw: failure,
                                version: store.version(of: pkg.manager))))
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(pkg.name).font(.body.weight(.medium)).lineLimit(1)
                    if pkg.isSecurity {
                        Label("Security", systemImage: "exclamationmark.shield.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .help(pkg.advisories.joined(separator: ", "))
                    }
                }
                // Longest phrasing that fits the available width: sentences → short words → icons.
                ViewThatFits(in: .horizontal) {
                    detailLine(style: .full)
                    detailLine(style: .short)
                    detailLine(style: .icons)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(DateText.tooltip(for: pkg, referenceDate: store.referenceDate(of: pkg)))
                if let failure = store.failure(for: pkg) {
                    Text(failure.split(separator: "\n").first.map(String.init) ?? failure)
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if store.isUpgrading(pkg) {
                ProgressView().controlSize(.small)
            } else if let failure = store.failure(for: pkg) {
                Button {
                    store.reveal(pkg)
                } label: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.borderless).help("Update failed:\n\(failure)\n\nClick to show the output.")
                .accessibilityLabel("Update failed, show output")
                Button("Retry") { Task { await store.upgrade(pkg) } }.controlSize(.small)
            } else {
                Button(pkg.manager.opensExternally ? "Open Settings" : "Update") { Task { await store.upgrade(pkg) } }
                    .controlSize(.small)
                    .help(eligible ? "Update \(pkg.name)" : "Update now, before the minimum age has passed")
            }
            if pkg.manager.supportsRemoval && !store.isUpgrading(pkg) {
                Button {
                    confirmAndRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove \(pkg.name)")
                .accessibilityLabel("Remove \(pkg.name)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .opacity(eligible ? 1 : 0.6)
    }

    private func confirmAndRemove() {
        if UpdateStore.confirmRemoval(of: pkg) { Task { await store.remove(pkg) } }
    }

    private enum DetailStyle { case full, short, icons }

    @ViewBuilder private func detailLine(style: DetailStyle) -> some View {
        let ref = store.referenceDate(of: pkg)
        HStack(spacing: 4) {
            Text("\(pkg.installed) → \(pkg.latest)").monospacedDigit().layoutPriority(1)
            Text("·")
            switch style {
            case .full:
                Text(ageText(ref, long: true))
                if let up = pkg.updatedAt {
                    Text("·")
                    Text("last updated \(up, format: .relative(presentation: .named))")
                }
            case .short:
                Text(ageText(ref, long: false))
                if let up = pkg.updatedAt {
                    Text("·")
                    Text("updated \(DateText.short(Date().timeIntervalSince(up)))")
                }
            case .icons:
                Label(ref.map { DateText.short(Date().timeIntervalSince($0)) } ?? "new", systemImage: releaseSymbol)
                if let up = pkg.updatedAt {
                    Text("·")
                    Label(DateText.short(Date().timeIntervalSince(up)), systemImage: "clock.arrow.circlepath")
                }
            }
            if pkg.isSystem {
                Text("·")
                if style == .icons { Image(systemName: "lock") } else { Label("macOS", systemImage: "lock") }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var releaseSymbol: String {
        switch pkg.dateSource {
        case .registry, .homebrew: "sparkles"
        case .firstSeen: "eye"
        }
    }

    private func ageText(_ ref: Date?, long: Bool) -> String {
        guard let ref else { return long ? "just found" : "new" }
        let rel =
            long
            ? ref.formatted(.relative(presentation: .named)) : "\(DateText.short(Date().timeIntervalSince(ref))) ago"
        switch pkg.dateSource {
        case .registry: return "released \(rel)"
        case .homebrew: return "bumped \(rel)"
        case .firstSeen: return long ? "first seen \(rel)" : "seen \(rel)"
        }
    }
}
