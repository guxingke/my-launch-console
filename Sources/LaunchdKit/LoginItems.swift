import Foundation
import ServiceManagement

/// One record from Background Task Management, the database behind
/// System Settings → General → Login Items & Extensions.
public struct BackgroundItem: Sendable, Equatable {
    /// e.g. `8.com.hapi.hub`: a type code, then the label or bundle ID.
    public var identifier: String
    public var name: String?
    public var developerName: String?
    public var teamID: String?
    public var type: String?
    public var isEnabled: Bool
    /// false when the user switched it off in Login Items.
    public var isAllowed: Bool
    public var url: String?
    public var executablePath: String?
    public var parentIdentifier: String?
    public var bundleID: String?

    /// The launchd label for agent, daemon and login-item records.
    public var label: String {
        guard let dot = identifier.firstIndex(of: "."), identifier[..<dot].allSatisfy(\.isNumber) else { return identifier }
        return String(identifier[identifier.index(after: dot)...])
    }

    public var isJob: Bool {
        guard let type else { return false }
        return type.hasPrefix("legacy agent") || type.hasPrefix("legacy daemon") || type.hasPrefix("agent")
            || type.hasPrefix("daemon") || type.hasPrefix("login item")
    }
}

/// What Login Items says about one job.
public struct LoginItemInfo: Sendable, Equatable, Codable {
    public var isAllowed: Bool
    /// The app it belongs to, e.g. "Adobe Creative Cloud".
    public var appName: String?
    public var developer: String?

    public init(isAllowed: Bool, appName: String? = nil, developer: String? = nil) {
        self.isAllowed = isAllowed
        self.appName = appName
        self.developer = developer
    }
}

public enum BackgroundItems {
    /// Parses `sfltool dumpbtm`. The format is undocumented, so unknown lines are ignored.
    /// sfltool shows home folders as `/Users/<uid>/`; those are mapped back to `home`.
    public static func parse(dump text: String, uid: uid_t = getuid(), home: String = NSHomeDirectory()) -> [BackgroundItem] {
        guard let start = text.range(of: "Records for UID \(uid) ") else { return [] }
        var section = text[start.upperBound...]
        if let next = section.range(of: "Records for UID ") { section = section[..<next.lowerBound] }

        var items: [BackgroundItem] = []
        var fields: [String: String] = [:]
        func flush() {
            defer { fields = [:] }
            guard let identifier = fields["Identifier"] else { return }
            let disposition = fields["Disposition"] ?? ""
            items.append(BackgroundItem(
                identifier: identifier,
                name: nonNull(fields["Name"]),
                developerName: nonNull(fields["Developer Name"]),
                teamID: nonNull(fields["Team Identifier"]),
                type: fields["Type"],
                isEnabled: disposition.contains("[enabled"),
                isAllowed: !disposition.contains("disallowed"),
                url: nonNull(fields["URL"]).map { unredact($0, uid: uid, home: home) },
                executablePath: nonNull(fields["Executable Path"]).map { unredact($0, uid: uid, home: home) },
                parentIdentifier: nonNull(fields["Parent Identifier"]),
                bundleID: nonNull(fields["Bundle Identifier"])
            ))
        }

        for line in section.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#"), trimmed.hasSuffix(":"), line.hasPrefix(" #") {
                flush()
                continue
            }
            guard let separator = trimmed.range(of: ": ") else { continue }
            let key = String(trimmed[..<separator.lowerBound])
            // Only the first occurrence: nested lists reuse "#1: …" lines.
            if fields[key] == nil {
                fields[key] = String(trimmed[separator.upperBound...])
            }
        }
        flush()
        return items
    }

    private static func nonNull(_ value: String?) -> String? {
        guard let value, value != "(null)", !value.isEmpty else { return nil }
        return value
    }

    private static func unredact(_ path: String, uid: uid_t, home: String) -> String {
        let redacted = "/Users/\(uid)/"
        return path.hasPrefix(redacted) ? home + "/" + path.dropFirst(redacted.count) : path
    }

    /// Login Items info per launchd label, with each job's parent app resolved.
    public static func infoByLabel(_ items: [BackgroundItem]) -> [String: LoginItemInfo] {
        let byIdentifier = Dictionary(items.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: LoginItemInfo] = [:]
        for item in items where item.isJob {
            let parent = item.parentIdentifier.flatMap { byIdentifier[$0] }
            // Legacy items name their app or vendor directly ("Adobe Creative Cloud").
            let appName = parent?.name ?? item.parentIdentifier.flatMap { $0 == "Unknown Developer" || $0.first?.isNumber == true ? nil : $0 }
            result[item.label] = LoginItemInfo(
                isAllowed: item.isAllowed,
                appName: appName,
                developer: item.developerName ?? parent?.developerName
            )
        }
        return result
    }

    /// Runs `sfltool dumpbtm`. Slow (around 20 s), so call it rarely and off the main thread.
    /// macOS asks for an administrator password first, so only call it when the user asks.
    public static func dump() async -> [BackgroundItem]? {
        guard let result = try? await Command.run("/usr/bin/sfltool", ["dumpbtm"]), result.status == 0 else { return nil }
        let items = parse(dump: result.stdout)
        return items.isEmpty ? nil : items
    }

    /// Whether Login Items allows a plist in a LaunchAgents folder. Fast, public API.
    /// nil when Login Items doesn't track it.
    public static func isAllowed(legacyPlist url: URL) -> Bool? {
        switch SMAppService.statusForLegacyPlist(at: url) {
        case .enabled: true
        case .requiresApproval: false
        default: nil
        }
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}

/// The last `sfltool dumpbtm` result, kept on disk so app and developer names show at launch
/// without asking for a password again.
public struct LoginItemCache: Codable, Sendable, Equatable {
    public var updated: Date
    public var info: [String: LoginItemInfo]

    public init(updated: Date = .now, info: [String: LoginItemInfo]) {
        self.updated = updated
        self.info = info
    }

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "LaunchConsole/login-items.json")
    }

    /// nil when there is no cache yet or it can't be read.
    public static func load(from url: URL = defaultURL) -> LoginItemCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LoginItemCache.self, from: data)
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Decides when a watched job deserves a notification: when it starts failing, not on every
/// respawn of a crash loop.
public struct FailureWatcher: Sendable {
    public struct Event: Sendable, Equatable {
        public var label: String
        public var message: String
    }

    /// At most one notification per job in this window.
    public var cooldown: TimeInterval = 15 * 60
    private var lastNotified: [String: Date] = [:]

    public init() {}

    /// - Parameter watched: job IDs (launchctl targets) to report on.
    public mutating func events(previous: [Job], current: [Job], watched: Set<String>, now: Date = .now) -> [Event] {
        guard !watched.isEmpty else { return [] }
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [Event] = []
        for job in current where watched.contains(job.id) {
            // A job seen for the first time (e.g. at launch) has no "before" to compare with.
            guard let old = before[job.id] else { continue }
            let message: String?
            if job.status == .failing, old.status != .failing {
                message = "Exited with \(job.service?.lastExit.description ?? "an error")."
            } else if job.issues.contains(.keepAliveNotRunning), !old.issues.contains(.keepAliveNotRunning) {
                message = "Stopped running, although KeepAlive is on."
            } else if old.isLoaded, !job.isLoaded, job.plist != nil, !job.isDisabled {
                message = "Was unloaded."
            } else {
                message = nil
            }
            guard let message else { continue }
            if let last = lastNotified[job.id], now.timeIntervalSince(last) < cooldown { continue }
            lastNotified[job.id] = now
            events.append(Event(label: job.label, message: message))
        }
        return events
    }
}
