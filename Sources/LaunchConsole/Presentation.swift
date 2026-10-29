import LaunchdKit
import SwiftUI

/// Sidebar scopes. Apple jobs are ~90% of the list, so the default hides them.
enum Scope: String, CaseIterable, Identifiable {
    case nonApple, everything
    case user, thirdParty, apple
    case systemThirdParty, systemApple

    var id: Self { self }

    static let overview: [Scope] = [.nonApple, .everything]
    static let agents: [Scope] = [.user, .thirdParty, .apple]
    static let daemons: [Scope] = [.systemThirdParty, .systemApple]

    var title: String {
        switch self {
        case .nonApple: "All Non-Apple"
        case .everything: "Everything"
        case .user: "My Agents"
        case .thirdParty: "Third-Party Agents"
        case .apple: "Apple Agents"
        case .systemThirdParty: "Third-Party Daemons"
        case .systemApple: "Apple Daemons"
        }
    }

    var systemImage: String {
        switch self {
        case .nonApple: "square.stack.3d.up"
        case .everything: "infinity"
        case .user: "person"
        case .thirdParty: "shippingbox"
        case .apple, .systemApple: "apple.logo"
        case .systemThirdParty: "gearshape.2"
        }
    }

    func includes(_ job: Job) -> Bool {
        switch self {
        case .nonApple: job.origin != .apple
        case .everything: true
        case .user: !job.isSystem && job.origin == .user
        case .thirdParty: !job.isSystem && (job.origin == .global || job.origin == .app)
        case .apple: !job.isSystem && job.origin == .apple
        case .systemThirdParty: job.isSystem && job.origin != .apple
        case .systemApple: job.isSystem && job.origin == .apple
        }
    }
}

extension Job {
    /// "Third-party", "Apple daemon", … for the Origin column.
    var originTitle: String {
        isSystem ? "\(origin == .global ? "Third-party" : origin.title) daemon" : origin.title
    }
}

enum StatusFilter: Hashable, CaseIterable, Identifiable {
    case any, needsAttention, status(JobStatus)

    static var allCases: [StatusFilter] {
        [.any, .needsAttention] + JobStatus.allCases.map(StatusFilter.status)
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .any: "Current Jobs"
        case .needsAttention: "Needs Attention"
        case .status(let status): status.title
        }
    }

    func includes(_ job: Job) -> Bool {
        switch self {
        // Leftover overrides are bookkeeping, not jobs; they get their own filter.
        case .any: job.status != .staleOverride
        case .needsAttention: (job.worstSeverity ?? .info) >= .warning
        case .status(let status): job.status == status
        }
    }
}

extension JobStatus {
    var systemImage: String {
        switch self {
        case .running: "circle.fill"
        case .failing: "exclamationmark.octagon.fill"
        case .idle: "circle"
        case .notLoaded: "circle.dashed"
        case .disabled: "nosign"
        case .staleOverride: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .failing: .red
        case .idle: .secondary
        case .notLoaded: .orange
        case .disabled, .staleOverride: .gray
        }
    }
}

extension Issue.Severity {
    var systemImage: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}

/// Sort keys for table columns whose natural values aren't Comparable.
extension Job {
    var pidSortKey: Int { pid ?? -1 }
    var exitSortKey: String { service?.lastExit.description ?? "" }
    var plistPath: String { plist?.url.path ?? "" }
}

struct StatusBadge: View {
    let status: JobStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .foregroundStyle(status.color)
            .labelStyle(.titleAndIcon)
    }
}

enum Format {
    /// e.g. "Every day at 03:00", "Sunday at 09:30", "Minute 15 of every hour".
    static func calendarInterval(_ interval: [String: Int]) -> String {
        var when: [String] = []
        if let month = interval["Month"], (1...12).contains(month) {
            when.append(Calendar.current.monthSymbols[month - 1])
        }
        if let day = interval["Day"] { when.append("day \(day)") }
        if let weekday = interval["Weekday"] {
            when.append(Calendar.current.weekdaySymbols[weekday % 7])
        }
        let date = when.isEmpty ? "Every day" : when.joined(separator: ", ")

        switch (interval["Hour"], interval["Minute"]) {
        case let (hour?, minute?): return "\(date) at \(String(format: "%02d:%02d", hour, minute))"
        case let (hour?, nil): return "\(date), every minute of hour \(hour)"
        case let (nil, minute?): return "\(date), minute \(minute) of every hour"
        case (nil, nil): return when.isEmpty ? "Every minute" : "\(date), every minute"
        }
    }

    static func seconds(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide))
    }

    static func keepAlive(_ keepAlive: KeepAlive) -> String {
        switch keepAlive {
        case .off: "No"
        case .always: "Always"
        case .conditional(let keys): "When: \(keys.joined(separator: ", "))"
        }
    }
}
