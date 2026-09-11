import AppKit
import SwiftUI

struct MainWindowView: View {
    @Environment(UpdateStore.self) private var store

    var body: some View {
        HSplitView {
            UpdatesView()
                .frame(minWidth: 340, idealWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            RightPane()
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .toolbar {
            ToolbarItem { SettingsLink { Label("Settings", systemImage: "gearshape") } }
        }
    }
}

/// Output log or action history, switched with a segmented control.
struct RightPane: View {
    @Environment(UpdateStore.self) private var store
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            if tab == 0 { LogView(tab: $tab) } else { HistoryView(tab: $tab) }
        }
        // Jump to the output when an error is revealed from a row.
        .onChange(of: store.revealCount) { _, _ in tab = 0 }
    }
}

struct PaneSwitch: View {
    @Binding var tab: Int
    var body: some View {
        Picker("", selection: $tab) {
            Text("Output").tag(0)
            Text("History").tag(1)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 150)
    }
}

struct HistoryView: View {
    @Environment(UpdateStore.self) private var store
    @Binding var tab: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PaneSwitch(tab: $tab)
                Spacer()
                Button("Clear") { store.history.clear() }.controlSize(.small).disabled(store.history.records.isEmpty)
            }
            .padding(.horizontal, 12).frame(height: 44)
            Divider()
            if store.history.records.isEmpty {
                Text("Updates, removals and ignores you perform will be listed here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.history.records) { HistoryRow(record: $0) }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct HistoryRow: View {
    let record: ActionRecord

    var body: some View {
        let r = record
        let tint: Color = r.succeeded ? (r.kind == .remove ? .orange : .green) : .red
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.body)
                if !r.detail.isEmpty {
                    Text(firstLine(r.detail)).font(.caption).foregroundStyle(r.succeeded ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(r.manager.title).font(.caption).foregroundStyle(.secondary)
                Text(r.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private func firstLine(_ s: String) -> String { s.split(separator: "\n").first.map(String.init) ?? s }

    private var icon: String {
        switch record.kind {
        case .upgrade: record.succeeded ? "arrow.up.circle.fill" : "xmark.circle.fill"
        case .remove: record.succeeded ? "trash.circle.fill" : "xmark.circle.fill"
        case .ignore: "eye.slash.circle.fill"
        case .unignore: "eye.circle.fill"
        case .install: record.succeeded ? "plus.circle.fill" : "xmark.circle.fill"
        }
    }
}

struct LogView: View {
    @Environment(UpdateStore.self) private var store
    @Binding var tab: Int
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PaneSwitch(tab: $tab)
                let failed = store.failures.count
                if failed > 0 {
                    Text("\(failed) failed").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.log, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .controlSize(.small).disabled(store.log.isEmpty)
                Button("Clear") { store.clearLog() }.controlSize(.small).disabled(store.log.isEmpty)
            }
            .padding(.horizontal, 12).frame(height: 44)
            Divider()
            LogTextView(text: store.log, revealMarker: store.revealMarker, revealCount: store.revealCount)
        }
    }
}

/// Native, selectable, read-only log. Follows new output only while the view is scrolled to the bottom,
/// so reading earlier output is never interrupted. Can scroll to the last occurrence of a marker line.
struct LogTextView: NSViewRepresentable {
    var text: String
    var revealMarker: String?
    var revealCount: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFindBar = true
        tv.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        tv.textColor = .labelColor
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let old = storage.string
        if old != text {
            let clip = scroll.contentView
            let wasAtBottom = (clip.bounds.maxY >= (tv.frame.height - 4)) || old.isEmpty
            let attrs: [NSAttributedString.Key: Any] = [.font: tv.font!, .foregroundColor: NSColor.labelColor]
            if text.hasPrefix(old) {
                storage.append(NSAttributedString(string: String(text.dropFirst(old.count)), attributes: attrs))
            } else {
                storage.setAttributedString(NSAttributedString(string: text, attributes: attrs))
            }
            if wasAtBottom { tv.scrollToEndOfDocument(nil) }
        }
        if revealCount != context.coordinator.lastReveal, let marker = revealMarker {
            context.coordinator.lastReveal = revealCount
            if let range = text.range(of: marker, options: .backwards) {
                let nsRange = NSRange(range, in: text)
                tv.scrollRangeToVisible(nsRange)
                tv.setSelectedRange(nsRange)
                // Put the marker at the top of the view so the error lines below it are visible.
                if let rect = tv.layoutManager?.boundingRect(forGlyphRange: nsRange, in: tv.textContainer!) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastReveal = 0 }
}
