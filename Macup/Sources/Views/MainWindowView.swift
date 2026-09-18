import AppKit
import SwiftUI

struct MainWindowView: View {
    @Environment(UpdateStore.self) private var store

    var body: some View {
        HSplitView {
            UpdatesView()
                .frame(minWidth: 340, idealWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HistoryView()
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .toolbar {
            ToolbarItem { SettingsLink { Label("Settings", systemImage: "gearshape") } }
        }
    }
}

/// Everything MacUp has done, newest first, and whatever it is doing right now.
///
/// There used to be a separate output pane. What a command printed is kept with the action it belongs
/// to, so a second place to look at the same text only made the window harder to navigate.
struct HistoryView: View {
    @Environment(UpdateStore.self) private var store
    @State private var expanded: Set<UUID> = []
    @State private var liveExpanded = false

    /// Records grouped by day, so a long history can be scanned by when rather than by scrolling.
    private var days: [(title: String, records: [ActionRecord])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [ActionRecord]] = [:]
        for record in store.history.records {
            let day = calendar.startOfDay(for: record.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(record)
        }
        return order.map { (Self.dayTitle($0, calendar: calendar), byDay[$0] ?? []) }
    }

    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.headline)
                let failed = store.failures.count
                if failed > 0 {
                    Text("^[\(failed) failure](inflect: true)").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Clear") { store.history.clear() }
                    .controlSize(.small).disabled(store.history.records.isEmpty)
            }
            .padding(.horizontal, 12).frame(height: 44)
            Divider()
            content
        }
    }

    @ViewBuilder private var content: some View {
        if store.history.records.isEmpty && !store.isBusy {
            Text("Updates, removals and ignores you perform will be listed here.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    if store.isBusy {
                        RunningRow(expanded: $liveExpanded)
                    }
                    ForEach(days, id: \.title) { day in
                        Section(day.title) {
                            ForEach(day.records) { record in
                                HistoryRow(
                                    record: record, expanded: expanded.contains(record.id),
                                    toggle: { toggle(record) }
                                )
                                .id(record.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                // "Show details" on a failed package opens that action here instead of jumping to a
                // separate log, which is the reason the output pane is gone.
                .onChange(of: store.revealCount) { _, _ in
                    guard let target = store.revealTarget,
                        let record = store.history.latestRecord(for: target)
                    else {
                        liveExpanded = store.isBusy
                        return
                    }
                    expanded.insert(record.id)
                    withAnimation { proxy.scrollTo(record.id, anchor: .center) }
                }
            }
        }
    }

    private func toggle(_ record: ActionRecord) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded.contains(record.id) { expanded.remove(record.id) } else { expanded.insert(record.id) }
        }
    }
}

/// What MacUp is doing at this moment, with the live output behind it.
struct RunningRow: View {
    @Environment(UpdateStore.self) private var store
    @Binding var expanded: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.activityTitle).font(.body)
                    if let detail = store.activityDetail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !store.log.isEmpty {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
            if expanded, !store.log.isEmpty {
                HStack {
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        Support.copy(store.log)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    }
                    .controlSize(.small)
                }
                LogTextView(text: store.log, revealMarker: store.revealMarker, revealCount: store.revealCount)
                    .frame(height: 240)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
        .padding(.vertical, 2)
    }
}

struct HistoryRow: View {
    let record: ActionRecord
    /// Held by the pane rather than the row, so "show details" elsewhere can open the right one.
    let expanded: Bool
    let toggle: () -> Void

    /// An empty string is the same as no output at all, so neither gets a disclosure arrow.
    private var output: String? {
        guard let output = record.output, !output.isEmpty else { return nil }
        return output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summary
            if expanded, let output {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Copy Output") { Support.copy(output) }.controlSize(.small)
                }
                ScrollView {
                    Text(output)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: some View {
        let r = record
        let tint: Color = r.succeeded ? (r.kind == .remove ? .orange : .green) : .red
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            // Output is kept for a week, so older entries have nothing to show.
            if output != nil {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        // The whole row, not just the arrow: a one-line target on the right edge is a poor thing to
        // ask someone to hit when the row itself is what they are looking at.
        .contentShape(Rectangle())
        .onTapGesture { if output != nil { toggle() } }
        .accessibilityAddTraits(output != nil ? .isButton : [])
        .accessibilityLabel(expanded ? "Hide what the command printed" : "Show what the command printed")
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
