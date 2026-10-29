import Foundation

/// When launchd starts a job on a timer.
public enum ScheduleRule: Sendable, Equatable {
    /// `StartInterval`: every N seconds, counted from the previous run.
    case interval(seconds: Int)
    /// `StartCalendarInterval`: cron-like dates.
    case calendar([[String: Int]])

    /// Every timer rule a plist has. A plist can have both.
    public static func rules(for plist: PlistJob) -> [ScheduleRule] {
        var rules: [ScheduleRule] = []
        if let seconds = plist.startInterval, seconds > 0 { rules.append(.interval(seconds: seconds)) }
        if !plist.calendarIntervals.isEmpty { rules.append(.calendar(plist.calendarIntervals)) }
        return rules
    }
}

public enum Schedule {
    /// How far ahead to look for a calendar match. Covers rules like "February 29".
    static let searchDays = 366 * 8

    /// The next time one `StartCalendarInterval` entry fires strictly after `date`.
    ///
    /// Missing keys are wildcards. As in cron, when both Day and Weekday are set a day
    /// matches if either does. Weekday 0 and 7 are both Sunday.
    public static func nextFire(_ interval: [String: Int], after date: Date, calendar: Calendar = .current) -> Date? {
        let minutes = interval["Minute"].map { [$0] } ?? Array(0..<60)
        let hours = interval["Hour"].map { [$0] } ?? Array(0..<24)
        guard minutes.allSatisfy((0...59).contains), hours.allSatisfy((0...23).contains) else { return nil }

        var day = calendar.startOfDay(for: date)
        for _ in 0..<searchDays {
            if matches(day: day, interval, calendar: calendar) {
                for hour in hours {
                    for minute in minutes {
                        guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
                        if candidate > date { return candidate }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    static func matches(day: Date, _ interval: [String: Int], calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.month, .day, .weekday], from: day)
        if let month = interval["Month"], month != components.month { return false }
        let dayMatches = interval["Day"].map { $0 == components.day }
        // Calendar weekdays are 1 (Sunday) … 7; launchd's are 0 or 7 (Sunday) … 6.
        let weekdayMatches = interval["Weekday"].map { $0 % 7 == (components.weekday ?? 1) - 1 }
        switch (dayMatches, weekdayMatches) {
        case let (day?, weekday?): return day || weekday
        case let (day?, nil): return day
        case let (nil, weekday?): return weekday
        case (nil, nil): return true
        }
    }

    /// Calendar fire times in `(start, end]`, across all entries, sorted. At most `limit`.
    public static func calendarFires(_ intervals: [[String: Int]], from start: Date, to end: Date, limit: Int = 500, calendar: Calendar = .current) -> [Date] {
        var fires: Set<Date> = []
        for interval in intervals {
            var cursor = start
            while fires.count < limit, let next = nextFire(interval, after: cursor, calendar: calendar), next <= end {
                fires.insert(next)
                cursor = next
            }
        }
        return Array(fires.sorted().prefix(limit))
    }

    /// `StartInterval` runs in `(start, end]`, projected from the last run.
    /// Without a known last run the phase is unknown, so there's nothing to project.
    public static func intervalFires(seconds: Int, lastRun: Date?, from start: Date, to end: Date, limit: Int = 500) -> [Date] {
        guard seconds > 0, let lastRun else { return [] }
        let step = TimeInterval(seconds)
        var next = lastRun + step
        if next <= start {
            next = lastRun + (floor(start.timeIntervalSince(lastRun) / step) + 1) * step
        }
        var fires: [Date] = []
        while next <= end, fires.count < limit {
            fires.append(next)
            next += step
        }
        return fires
    }

    /// Upcoming runs for a set of rules, merged and sorted.
    public static func upcoming(_ rules: [ScheduleRule], lastRun: Date?, from start: Date, to end: Date, calendar: Calendar = .current) -> [Date] {
        var fires: [Date] = []
        for rule in rules {
            switch rule {
            case .interval(let seconds): fires += intervalFires(seconds: seconds, lastRun: lastRun, from: start, to: end)
            case .calendar(let intervals): fires += calendarFires(intervals, from: start, to: end, calendar: calendar)
            }
        }
        return fires.sorted()
    }
}

/// One start or exit of a job, from launchd's own log messages.
public struct RunEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `Successfully spawned X[pid] because <reason>`.
        case started(reason: String)
        /// `exited due to exit(N)`; nil code for signals and other causes.
        case exited(code: Int?, description: String)
    }

    public var label: String
    public var date: Date
    public var kind: Kind

    public var isFailedExit: Bool {
        if case .exited(let code, let description) = kind {
            return code.map { $0 != 0 } ?? !description.contains("SIGTERM")
        }
        return false
    }
}

extension UnifiedLog {
    /// Predicate for launchd's start and exit messages for several jobs at once.
    public static func runHistoryPredicate(domain: String, labels: [String]) -> String {
        let subsystems = labels.map { "subsystem BEGINSWITH \(quote("\(domain)/\($0) ["))" }.joined(separator: " OR ")
        return "process == \"launchd\" AND (eventMessage BEGINSWITH \"Successfully spawned\" OR eventMessage BEGINSWITH \"exited \") AND (\(subsystems))"
    }

    /// Starts and exits per label, oldest first.
    public static func runHistory(domain: String, labels: [String], last: Duration) async throws -> [String: [RunEvent]] {
        guard !labels.isEmpty else { return [:] }
        let entries = try await show(predicate: runHistoryPredicate(domain: domain, labels: labels), last: last, limit: 20_000)
        return parseRunHistory(entries, domain: domain)
    }

    public static func parseRunHistory(_ entries: [LogEntry], domain: String) -> [String: [RunEvent]] {
        var result: [String: [RunEvent]] = [:]
        let prefix = domain + "/"
        for entry in entries {
            guard let date = entry.date, let subsystem = entry.subsystem, subsystem.hasPrefix(prefix) else { continue }
            // `gui/501/com.example.job [1234]`
            let rest = subsystem.dropFirst(prefix.count)
            let label = String(rest.split(separator: " [", maxSplits: 1).first ?? rest)
            let message = entry.message
            let kind: RunEvent.Kind
            if message.hasPrefix("Successfully spawned"), let range = message.range(of: " because ") {
                kind = .started(reason: String(message[range.upperBound...]))
            } else if message.hasPrefix("exited ") {
                let description = message.dropFirst("exited ".count).split(separator: ",").first.map(String.init) ?? message
                var code: Int?
                if let open = message.range(of: "exit("), let close = message[open.upperBound...].firstIndex(of: ")") {
                    code = Int(message[open.upperBound..<close])
                }
                kind = .exited(code: code, description: description)
            } else {
                continue
            }
            result[label, default: []].append(RunEvent(label: label, date: date, kind: kind))
        }
        return result
    }
}

extension Array where Element == RunEvent {
    public var lastStart: Date? {
        last { if case .started = $0.kind { true } else { false } }?.date
    }
}
