import LaunchdKit
import SwiftUI

enum ScheduleRange: Int, CaseIterable, Identifiable {
    case day = 1, week = 7
    var id: Self { self }
    var title: String { self == .day ? "Next 24 Hours" : "Next 7 Days" }
    var ahead: TimeInterval { TimeInterval(rawValue) * 86_400 }
}

/// One scheduled job, with its past runs and projected future ones.
struct ScheduleRow: Identifiable {
    var job: Job
    var rules: [ScheduleRule]
    var history: [RunEvent]
    var upcoming: [Date]
    /// False when the job can't run on schedule (not loaded or disabled).
    var willRun: Bool

    var id: String { job.label }

    var nextRun: Date? { willRun ? upcoming.first : nil }

    /// Interval jobs need one observed run to know their phase.
    var phaseUnknown: Bool {
        willRun && upcoming.isEmpty && rules.contains { if case .interval = $0 { true } else { false } }
    }

    var ruleText: String {
        rules.map { rule in
            switch rule {
            case .interval(let seconds): "Every \(Format.seconds(seconds))"
            case .calendar(let intervals): intervals.map(Format.calendarInterval).joined(separator: "; ")
            }
        }
        .joined(separator: "; ")
    }
}

/// Upcoming and recent timer-driven runs, for jobs with StartInterval or StartCalendarInterval.
struct ScheduleView: View {
    @Environment(JobStore.self) private var store
    @State private var range: ScheduleRange = .day
    @State private var includeApple = false
    @State private var history: [String: [RunEvent]] = [:]
    @State private var historyError: String?
    @State private var isLoadingHistory = false
    @State private var now = Date.now

    static let lookBack: TimeInterval = 86_400

    private var scheduledJobs: [Job] {
        store.jobs.filter { job in
            guard let plist = job.plist, !ScheduleRule.rules(for: plist).isEmpty else { return false }
            return includeApple || job.origin != .apple
        }
    }

    private var rows: [ScheduleRow] {
        let end = now + range.ahead
        return scheduledJobs.map { job in
            let rules = ScheduleRule.rules(for: job.plist!)
            let events = history[job.id] ?? []
            let willRun = job.isLoaded && !job.isDisabled
            let upcoming = willRun ? Schedule.upcoming(rules, lastRun: events.lastStart, from: now, to: end) : []
            return ScheduleRow(job: job, rules: rules, history: events, upcoming: upcoming, willRun: willRun)
        }
        .sorted { lhs, rhs in
            switch (lhs.nextRun, rhs.nextRun) {
            case let (l?, r?): l < r
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.job.label < rhs.job.label
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if rows.isEmpty {
                ContentUnavailableView("No Scheduled Jobs", systemImage: "calendar",
                                       description: Text("No job here uses StartInterval or StartCalendarInterval."))
            } else {
                List(rows) { row in
                    ScheduleRowView(row: row, now: now, start: now - Self.lookBack, end: now + range.ahead)
                        .padding(.vertical, 4)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 360)
        .task(id: "\(includeApple)|\(scheduledJobs.map(\.label).joined(separator: ","))") {
            await loadHistory()
        }
        .task {
            // Keep "in 5 min" and the now line moving.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = .now
            }
        }
    }

    private var controls: some View {
        HStack {
            Picker("Range", selection: $range) {
                ForEach(ScheduleRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle("Include Apple jobs", isOn: $includeApple)
                .toggleStyle(.checkbox)
            Spacer()
            if isLoadingHistory {
                ProgressView().controlSize(.small)
                Text("Reading the last 24 hours of launchd's log…").foregroundStyle(.secondary)
            } else if let historyError {
                Label(historyError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Button("Reload History", systemImage: "arrow.clockwise") {
                Task { await loadHistory() }
            }
            .labelStyle(.iconOnly)
            .disabled(isLoadingHistory)
        }
        .controlSize(.small)
        .padding(8)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            LegendMark(color: .green, filled: true, text: "Ran")
            LegendMark(color: .red, filled: true, text: "Failed")
            LegendMark(color: .accentColor, filled: false, text: "Scheduled")
            Spacer()
            Text("Asleep at a scheduled time? launchd runs a missed calendar job once on wake, and interval jobs drift. Upcoming interval runs are projected from the last run in the log.")
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .font(.caption)
        .padding(8)
    }

    private func loadHistory() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            // One query per domain; keyed by job ID so the same label in both domains stays apart.
            var merged: [String: [RunEvent]] = [:]
            for (domain, jobs) in Dictionary(grouping: scheduledJobs, by: \.domain) {
                let found = try await UnifiedLog.runHistory(domain: domain, labels: jobs.map(\.label), last: .seconds(Int(Self.lookBack)))
                for (label, events) in found { merged["\(domain)/\(label)"] = events }
            }
            history = merged
            historyError = nil
        } catch {
            historyError = "Couldn't read past runs: \(error.localizedDescription)"
        }
        now = .now
    }
}

private struct LegendMark: View {
    let color: Color
    let filled: Bool
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .strokeBorder(color, lineWidth: 1.5)
                .background(Circle().fill(filled ? color : .clear))
                .frame(width: 8, height: 8)
            Text(text)
        }
    }
}

struct ScheduleRowView: View {
    let row: ScheduleRow
    let now: Date
    let start: Date
    let end: Date

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.job.label).lineLimit(1).truncationMode(.middle)
                    StatusBadge(status: row.job.status).labelStyle(.iconOnly).font(.caption)
                }
                Text(row.ruleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 260, alignment: .leading)

            Timeline(row: row, now: now, start: start, end: end)
                .frame(height: 22)

            VStack(alignment: .trailing, spacing: 2) {
                Text(nextText)
                    .foregroundStyle(row.willRun ? .primary : .secondary)
                if let last = row.history.lastStart {
                    Text("Last: \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, alignment: .trailing)
        }
    }

    private var nextText: String {
        if !row.willRun {
            if row.job.isDisabled { return "Disabled" }
            return row.job.loginItem?.isAllowed == false ? "Off in Login Items" : "Not loaded"
        }
        if let next = row.nextRun { return next.formatted(.relative(presentation: .named)) }
        if row.phaseUnknown { return "After its first run" }
        return "Not in range"
    }
}

/// A strip from `start` to `end`: past runs on the left of the now line, scheduled ones on the right.
private struct Timeline: View {
    let row: ScheduleRow
    let now: Date
    let start: Date
    let end: Date

    var body: some View {
        Canvas { context, size in
            let span = end.timeIntervalSince(start)
            // Inset so dots at either end aren't cut in half.
            let inset: CGFloat = 4
            func x(_ date: Date) -> CGFloat { inset + CGFloat(date.timeIntervalSince(start) / span) * (size.width - 2 * inset) }
            let mid = size.height / 2

            context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(.secondary.opacity(0.3)))
            for event in row.history where event.date >= start && event.date <= now {
                switch event.kind {
                case .started:
                    let dot = CGRect(x: x(event.date) - 2.5, y: mid - 2.5, width: 5, height: 5)
                    context.fill(Path(ellipseIn: dot), with: .color(.green))
                case .exited where event.isFailedExit:
                    let dot = CGRect(x: x(event.date) - 3, y: mid - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dot), with: .color(.red))
                case .exited:
                    break
                }
            }
            // Sub-minute intervals would be a solid smear of circles; draw a bar instead.
            let dense = row.upcoming.count > Int(size.width / 4)
            if dense, let first = row.upcoming.first, let last = row.upcoming.last {
                context.fill(Path(CGRect(x: x(first), y: mid - 2, width: max(1, x(last) - x(first)), height: 4)), with: .color(.accentColor.opacity(0.6)))
            } else {
                for date in row.upcoming {
                    let dot = CGRect(x: x(date) - 3, y: mid - 3, width: 6, height: 6)
                    context.stroke(Path(ellipseIn: dot), with: .color(.accentColor), lineWidth: 1.5)
                }
            }
            context.fill(Path(CGRect(x: x(now) - 0.5, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.6)))
        }
        .help(helpText)
    }

    private var helpText: String {
        let upcoming = row.upcoming.prefix(5).map { $0.formatted(date: .abbreviated, time: .shortened) }
        return upcoming.isEmpty ? row.ruleText : "Next: " + upcoming.joined(separator: ", ")
    }
}
