import SwiftUI

/// The menu bar dropdown, styled after the system Wi-Fi / Control Center panels:
/// a narrow vertical list with circular icons, thin dividers and plain hover-highlighted action rows.
struct MenuBarPanel: View {
    @Environment(UpdateStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showWaiting = false

    var body: some View {
        let eligible = store.eligible
        let waiting = store.waiting
        VStack(alignment: .leading, spacing: 0) {
            header
            if let cask = store.selfCaskUpdate { appUpdateRow(cask) }
            if eligible.isEmpty && waiting.isEmpty {
                allGood
            } else {
                list(eligible: eligible, waiting: waiting)
            }
            notices
            PanelDivider()
            footer(eligibleCount: eligible.count)
        }
        .padding(.vertical, 6)
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                if store.updatableCount > 0 {
                    Button {
                        Task { await store.upgradeAllEligible() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title3)
                    }
                    .buttonStyle(.borderless).disabled(store.isUpgradingAnything)
                    .accessibilityLabel("Update all")
                    .help(store.isUpgradingAnything ? "Updating…" : "Update all \(store.updatableCount)")
                }
                if store.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await store.scan() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.body.weight(.medium))
                    }
                    .buttonStyle(.borderless).help("Check now").accessibilityLabel("Check now")
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 8)
    }

    private var title: String {
        if store.isScanning && store.packages.isEmpty { return "Checking for updates…" }
        let n = store.badgeCount
        if n == 0 { return "Up to date" }
        return "\(n) update\(n == 1 ? "" : "s") ready"
    }

    private var subtitle: String {
        if store.isScanning { return "Scanning package managers…" }
        if let last = store.lastScan { return "Checked \(last.formatted(.relative(presentation: .named)))" }
        return "Not checked yet"
    }

    /// Homebrew installs: MacUp's own cask is outdated. Upgrading it relaunches the app.
    private func appUpdateRow(_ cask: OutdatedPackage) -> some View {
        VStack(spacing: 0) {
            PanelDivider()
            Button {
                Task { await store.upgrade(cask) }
            } label: {
                HStack(spacing: 10) {
                    IconCircle(symbol: "shippingbox.fill", tint: .accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MacUp \(cask.latest) is available").font(.body)
                        Text("You have \(cask.installed). Updates with Homebrew and relaunches.").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isUpgrading(cask) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle").font(.title3).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 3)
            }
            .buttonStyle(MenuRowStyle()).disabled(store.isUpgradingAnything)
        }
    }

    // MARK: List

    private func list(eligible: [OutdatedPackage], waiting: [OutdatedPackage]) -> some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(Manager.allCases) { manager in
                let items = eligible.filter { $0.manager == manager }
                if !items.isEmpty {
                    PanelDivider()
                    sectionHeader(manager, count: items.count)
                    ForEach(items) { PanelRow(pkg: $0, dimmed: false) }
                }
            }
            if !waiting.isEmpty {
                PanelDivider()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showWaiting.toggle() }
                } label: {
                    HStack {
                        Text("\(waiting.count) waiting for minimum age").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: showWaiting ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(MenuRowStyle())
                if showWaiting {
                    ForEach(waiting) { PanelRow(pkg: $0, dimmed: true) }
                }
            }
        }
        // Long lists scroll; short ones size naturally so the panel never leaves empty space.
        return Group {
            if eligible.count + (showWaiting ? waiting.count : 0) > 9 {
                ScrollView { rows }.frame(height: 440)
            } else {
                rows
            }
        }
    }

    private func sectionHeader(_ manager: Manager, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(manager.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if store.needsAdmin(manager) {
                Image(systemName: "lock").font(.caption).foregroundStyle(.secondary)
                    .help("Updating asks for your administrator password")
            }
            Spacer()
            if count > 1 || manager == .rustup {
                Button("Update All") { Task { await store.upgradeAll(manager) } }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(store.isUpgradingAnything)
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
    }

    private var allGood: some View {
        VStack(spacing: 0) {
            PanelDivider()
            HStack(spacing: 10) {
                IconCircle(symbol: "checkmark", tint: .green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Everything is up to date").font(.body)
                    Text("\(store.discoveredManagers.count) package managers checked").font(.caption).foregroundStyle(
                        .secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    @ViewBuilder private var notices: some View {
        if let err = store.scanError {
            noticeRow(err, symbol: "exclamationmark.triangle", tint: .red)
        }
        if store.isOffline { OfflineRow(compact: true) }
        ForEach(store.problems) { ProblemRow(report: $0, compact: true) }
    }

    private func noticeRow(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).font(.caption)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
    }

    // MARK: Footer

    private func footer(eligibleCount: Int) -> some View {
        VStack(spacing: 0) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Text("Settings")
            }
            .buttonStyle(MenuRowStyle())
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("Open MacUp")
            }
            .buttonStyle(MenuRowStyle())
            PanelDivider()
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
            }.buttonStyle(MenuRowStyle())
        }
    }
}

// MARK: - Pieces

/// One package: circular manager icon, name, version line, age and a single action.
struct PanelRow: View {
    @Environment(UpdateStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let pkg: OutdatedPackage
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 10) {
            IconCircle(
                symbol: pkg.isSecurity ? "exclamationmark.shield.fill" : pkg.manager.symbol,
                tint: pkg.isSecurity ? .red : (dimmed ? .gray : .accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(pkg.name).font(.body).lineLimit(1)
                Text("\(pkg.installed) → \(pkg.latest) · \(ageText)\(updatedText)\(pkg.isSystem ? " · macOS" : "")")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            .help(DateText.tooltip(for: pkg, referenceDate: store.referenceDate(of: pkg)))
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .opacity(dimmed ? 0.6 : 1)
        .contextMenu {
            Button("Ignore \(pkg.name)") { store.ignore(pkg) }
            if pkg.manager.supportsRemoval {
                Button("Remove \(pkg.name)…") {
                    if UpdateStore.confirmRemoval(of: pkg) { Task { await store.remove(pkg) } }
                }
            }
            if let failure = store.failure(for: pkg) {
                Button("Retry Update") { Task { await store.upgrade(pkg) } }
                Button("Copy Error") {
                    Support.copy(
                        Support.details(title: "Update of \(pkg.name) failed", manager: pkg.manager, raw: failure))
                }
                Button("Report on GitHub…") {
                    NSWorkspace.shared.open(
                        Support.issueURL(
                            title: "\(pkg.manager.title): update of \(pkg.name) failed",
                            body: Support.details(
                                title: "Update of \(pkg.name) failed", manager: pkg.manager, raw: failure)))
                }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if store.isUpgrading(pkg) {
            ProgressView().controlSize(.small)
        } else if let failure = store.failure(for: pkg) {
            Button {
                store.reveal(pkg)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.title3)
            }
            .buttonStyle(.borderless).help(
                "Update failed:\n\(failure)\n\nClick to see the output. Right-click to retry."
            )
            .accessibilityLabel("Update failed, show output")
        } else {
            Button {
                Task { await store.upgrade(pkg) }
            } label: {
                Image(systemName: pkg.manager.opensExternally ? "arrow.up.forward.app" : "arrow.up.circle").font(
                    .title3)
            }
            .buttonStyle(.borderless)
            .help(
                pkg.manager.opensExternally
                    ? "Open Software Update in System Settings"
                    : dimmed ? "Update now, before the minimum age has passed" : "Update \(pkg.name)"
            )
            .accessibilityLabel(pkg.manager.opensExternally ? "Open Software Update" : "Update \(pkg.name)")
        }
    }

    private var ageText: String {
        guard let ref = store.referenceDate(of: pkg) else { return "new" }
        return "\(DateText.short(Date().timeIntervalSince(ref))) ago"
    }

    private var updatedText: String {
        guard let up = pkg.updatedAt else { return "" }
        return " · updated \(DateText.short(Date().timeIntervalSince(up)))"
    }
}

struct IconCircle: View {
    let symbol: String
    let tint: Color
    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(tint == .gray ? 0.25 : 0.9))
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint == .gray ? Color.primary : Color.white)
        }
        .frame(width: 30, height: 30)
    }
}

struct PanelDivider: View {
    var body: some View { Divider().padding(.horizontal, 10).padding(.vertical, 4) }
}

/// Plain full-width text row that highlights on hover, like rows in the system menu bar panels.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(MenuRowHighlight(pressed: configuration.isPressed))
    }
}

private struct MenuRowHighlight: ViewModifier {
    var pressed: Bool
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered || pressed ? Color.primary.opacity(pressed ? 0.16 : 0.09) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .padding(.horizontal, 4)
    }
}
