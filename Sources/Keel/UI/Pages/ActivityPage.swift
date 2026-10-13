import SwiftUI

/// Everything Keel ran, newest first, grouped by day.
struct ActivityPage: View {
    let log: ActivityLog
    @State private var levels: Set<LogLevel> = Set(LogLevel.allCases)
    @State private var expanded: Set<UUID> = []
    @State private var query = ""
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private struct Day: Identifiable { let id: Date; let entries: [LogEntry] }

    var body: some View {
        let q = query.lowercased()
        let visible = log.entries.reversed().filter { levels.contains($0.level) && (q.isEmpty || $0.message.lowercased().contains(q) || ($0.detail?.lowercased().contains(q) ?? false)) }
        let cal = Calendar.current
        var days: [Day] = []
        var current: [LogEntry] = []
        var currentDay: Date? = nil
        for e in visible {
            let d = cal.startOfDay(for: e.date)
            if d != currentDay, let cd = currentDay { days.append(Day(id: cd, entries: current)); current = [] }
            currentDay = d
            current.append(e)
        }
        if let cd = currentDay { days.append(Day(id: cd, entries: current)) }
        let counts = Dictionary(grouping: log.entries, by: \.level).mapValues(\.count)
        return VStack(spacing: 0) {
            PageHeader(title: "Activity", subtitle: "\(log.entries.count) entries · every command Keel ran, in plain language") {
                Button { export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Button("Clear") { confirmClear = true }.disabled(log.entries.isEmpty)
            }
            HStack(spacing: 6) {
                ForEach(LogLevel.allCases, id: \.self) { l in
                    ChipButton(text: l.label, selected: levels.contains(l), count: counts[l] ?? 0) {
                        if levels.contains(l) { levels.remove(l) } else { levels.insert(l) }
                    }
                }
                Spacer(minLength: 8)
                SearchField(text: $query, prompt: "Search activity", focus: $searchFocused).frame(minWidth: 150, maxWidth: 230)
            }
            .padding(.horizontal, 20).padding(.bottom, 10)
            HLine()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.entries) { e in row(e) }
                        } header: {
                            Text(dayTitle(day.id)).font(Theme.label).tracking(0.6).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20).padding(.vertical, 6)
                                .background(Theme.bg)
                        }
                    }
                    if visible.isEmpty { EmptyNote(symbol: "list.bullet.rectangle", text: log.entries.isEmpty ? "Nothing yet. Every change Keel makes is logged here." : "No entries match.") }
                }
                .padding(.bottom, 12)
            }
        }
        .confirmationDialog("Clear the activity log?", isPresented: $confirmClear) {
            Button("Clear log", role: .destructive) { log.clear() }
        } message: {
            Text("This removes the log file. Recorded originals are kept, so restoring still works.")
        }
    }

    private func row(_ e: LogEntry) -> some View {
        let open = expanded.contains(e.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(e.date.formatted(date: .omitted, time: .standard)).font(Theme.monoSmall).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize().frame(width: 96, alignment: .leading)
                Chip(text: e.level.label, color: Theme.color(for: e.level)).frame(width: 50, alignment: .leading)
                Text(e.message).font(e.level == .command ? Theme.monoSmall : .system(size: 12.5))
                    .foregroundStyle(e.level == .error ? Theme.fail : .primary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if e.detail != nil {
                    IconButton(symbol: open ? "chevron.up" : "chevron.down", label: open ? "Hide output" : "Show output", size: 10) {
                        if open { expanded.remove(e.id) } else { expanded.insert(e.id) }
                    }
                }
            }
            if open, let d = e.detail {
                CommandBlock(lines: d.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)).padding(.leading, 166)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 20)
        .overlay(alignment: .bottom) { HLine().padding(.leading, 20) }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "TODAY" }
        if cal.isDateInYesterday(d) { return "YESTERDAY" }
        return d.formatted(date: .abbreviated, time: .omitted).uppercased()
    }

    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "keel-activity.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let entries = log.entries
        Task.detached(priority: .utility) {
            let text = entries.map { "\($0.date.formatted(.iso8601)) [\($0.level.label)] \($0.message)\($0.detail.map { "\n    " + $0.replacingOccurrences(of: "\n", with: "\n    ") } ?? "")" }.joined(separator: "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
