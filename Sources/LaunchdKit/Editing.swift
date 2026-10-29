import Foundation

public struct ValidationIssue: Sendable, Equatable, Hashable {
    public enum Severity: Sendable, Equatable, Hashable {
        /// Saving is blocked.
        case error
        /// Saving is allowed, but the job probably won't do what you expect.
        case warning
    }

    public var severity: Severity
    public var message: String

    public static func error(_ message: String) -> ValidationIssue { .init(severity: .error, message: message) }
    public static func warning(_ message: String) -> ValidationIssue { .init(severity: .warning, message: message) }
}

/// Checks a definition against what launchd will actually do with it.
/// The file-system probes are injectable so the rules can be tested without real files.
public struct Validator: Sendable {
    public var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    public var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    public init() {}

    static let calendarRanges: [String: ClosedRange<Int>] = [
        "Minute": 0...59, "Hour": 0...23, "Day": 1...31, "Weekday": 0...7, "Month": 1...12,
    ]

    /// Keys that start a job on their own, besides the ones the form edits.
    static let otherTriggers: Set<String> = ["Sockets", "MachServices", "QueueDirectories", "StartOnMount", "LaunchEvents"]

    /// - Parameters:
    ///   - fileName: the plist's file name, e.g. `com.example.job.plist`.
    ///   - takenLabels: labels already used by other jobs in the domain.
    public func validate(_ definition: JobDefinition, fileName: String, takenLabels: Set<String>) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let label = definition.label

        if label.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.error("Enter a label, e.g. local.yourname.backup."))
        } else if label.contains(where: { $0.isWhitespace || $0 == "/" }) {
            issues.append(.error("The label can't contain spaces or slashes."))
        } else {
            if takenLabels.contains(label) {
                issues.append(.error("Another job already uses the label \(label)."))
            }
            if fileName != "\(label).plist" {
                issues.append(.warning("The file is named \(fileName), which doesn't match the label. launchd allows it, but it's confusing."))
            }
        }

        let arguments = definition.arguments
        if let program = arguments.first, !program.isEmpty {
            if program.hasPrefix("~") {
                issues.append(.error("launchd doesn't expand ~ in the program path. Use the full path."))
            } else if !program.hasPrefix("/") {
                issues.append(.warning("\(program) isn't a full path. launchd only searches /usr/bin, /bin, /usr/sbin and /sbin."))
            } else if !exists(program) {
                issues.append(.error("\(program) doesn't exist."))
            } else if !isExecutable(program) {
                issues.append(.error("\(program) isn't executable."))
            }
            if arguments.dropFirst().contains(where: { $0.hasPrefix("~/") }) {
                issues.append(.warning("An argument starts with ~/. launchd passes it literally; it isn't expanded."))
            }
        } else {
            issues.append(.error("Choose the program to run."))
        }

        let hasTrigger = definition.runAtLoad || definition.keepAlive != .off || definition.startInterval != nil
            || !definition.calendarIntervals.isEmpty || !definition.watchPaths.isEmpty
            || !Self.otherTriggers.isDisjoint(with: definition.dictionary.keys)
        if !hasTrigger {
            issues.append(.warning("Nothing will start this job automatically. It only runs when started by hand."))
        }
        if let interval = definition.startInterval, interval <= 0 {
            issues.append(.error("The interval must be at least 1 second."))
        }
        for interval in definition.calendarIntervals {
            for (key, value) in interval {
                if let range = Self.calendarRanges[key] {
                    if !range.contains(value) {
                        issues.append(.error("Schedule \(key) must be between \(range.lowerBound) and \(range.upperBound)."))
                    }
                } else {
                    issues.append(.error("\(key) isn't a schedule field. Use Minute, Hour, Day, Weekday or Month."))
                }
            }
        }
        for path in definition.watchPaths where !path.hasPrefix("~") && !exists(path) {
            issues.append(.warning("Watched path \(path) doesn't exist yet."))
        }

        for (name, path) in [("Standard output", definition.stdoutPath), ("Standard error", definition.stderrPath)] where !path.isEmpty {
            if path.hasPrefix("~") {
                issues.append(.error("\(name): launchd doesn't expand ~. Use the full path."))
            } else if !path.hasPrefix("/") {
                issues.append(.error("\(name) must be a full path."))
            } else {
                let folder = (path as NSString).deletingLastPathComponent
                if !exists(folder) {
                    issues.append(.warning("\(name): the folder \(folder) doesn't exist, and launchd won't create it."))
                }
            }
        }
        let workingDirectory = definition.workingDirectory
        if !workingDirectory.isEmpty, !exists(workingDirectory) {
            issues.append(.warning("Working directory \(workingDirectory) doesn't exist."))
        }
        if definition.environment.keys.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            issues.append(.error("An environment variable has no name."))
        }

        // Errors first, keeping each group's order.
        return issues.filter { $0.severity == .error } + issues.filter { $0.severity == .warning }
    }
}

public enum EditPolicy {
    /// Why the job's plist can't be edited, or nil when it can.
    public static func editReadOnlyReason(for job: Job) -> String? {
        guard let plist = job.plist else { return "There's no plist file for this job." }
        switch job.origin {
        case .apple: return "Apple jobs are read-only."
        case .global: return "This plist is in \(plist.url.deletingLastPathComponent().path) and belongs to root. Edit it with admin rights instead."
        case .app: return "This job is managed by an app."
        case .user: break
        }
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: plist.url.path) {
            return FileManager.default.fileExists(atPath: plist.url.path)
                ? "This plist is a symlink to \(target). Edit the original instead."
                : "This is a broken symlink, so there's nothing to edit. Move it to the Trash to clean it up."
        }
        if let error = plist.error { return "The plist can't be read: \(error)" }
        if !FileManager.default.isWritableFile(atPath: plist.url.path) {
            return "You don't have permission to change this file."
        }
        return nil
    }

    /// Only plists in the user's own LaunchAgents folder can be moved to the Trash,
    /// including broken symlinks (which is how leftover agents usually look).
    public static func canMoveToTrash(_ job: Job) -> Bool {
        job.origin == .user && job.plist != nil
    }

    /// Things worth knowing before editing.
    public static func notes(for label: String) -> [String] {
        if label.hasPrefix("homebrew.mxcl.") {
            return ["Homebrew manages this file. `brew services restart` or upgrading the formula rewrites it and drops your changes."]
        }
        return []
    }
}

public struct SaveResult: Sendable, Equatable {
    public var url: URL
    /// Where the previous version was copied, when there was one.
    public var backup: URL?
}

public enum PlistStoreError: Error, LocalizedError, Equatable {
    case alreadyExists(String)
    case lintFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let path): "\(path) already exists."
        case .lintFailed(let output): "plutil rejected the file: \(output)"
        }
    }
}

/// Writes plists without ever leaving a half-written file where launchd reads them:
/// write to a temp file next to the target, lint it, back up the old version, then swap.
public struct PlistStore: Sendable {
    public var agentsDirectory: URL
    public var backupDirectory: URL
    /// Moves a file to the Trash; injectable so tests don't fill the real one.
    public var trash: @Sendable (URL) throws -> URL?

    public init(agentsDirectory: URL, backupDirectory: URL, trash: @escaping @Sendable (URL) throws -> URL? = PlistStore.systemTrash) {
        self.agentsDirectory = agentsDirectory
        self.backupDirectory = backupDirectory
        self.trash = trash
    }

    public static func user(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PlistStore {
        PlistStore(
            agentsDirectory: home.appending(path: "Library/LaunchAgents"),
            backupDirectory: home.appending(path: "Library/Application Support/LaunchConsole/Backups")
        )
    }

    public static let systemTrash: @Sendable (URL) throws -> URL? = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    public func url(forLabel label: String) -> URL {
        agentsDirectory.appending(path: "\(label).plist")
    }

    /// Writes a new plist named after its label. Never overwrites.
    public func create(_ definition: JobDefinition) async throws -> SaveResult {
        let url = url(forLabel: definition.label)
        if FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw PlistStoreError.alreadyExists(url.path)
        }
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let temp = try await writeLintedTemp(definition, next: url)
        try FileManager.default.moveItem(at: temp, to: url)
        return SaveResult(url: url, backup: nil)
    }

    /// Replaces an existing plist, keeping a timestamped copy of the old one.
    public func save(_ definition: JobDefinition, to url: URL, now: Date = .now) async throws -> SaveResult {
        let temp = try await writeLintedTemp(definition, next: url)
        var backup: URL?
        if FileManager.default.fileExists(atPath: url.path) {
            let folder = backupDirectory.appending(path: url.deletingPathExtension().lastPathComponent)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(path: "\(Self.backupStamp(now)).plist")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            backup = destination
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
        return SaveResult(url: url, backup: backup)
    }

    public func moveToTrash(_ url: URL) throws -> URL? {
        try trash(url)
    }

    private func writeLintedTemp(_ definition: JobDefinition, next url: URL) async throws -> URL {
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try definition.xmlData().write(to: temp)
        let lint = try await Command.run("/usr/bin/plutil", ["-lint", temp.path])
        guard lint.status == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw PlistStoreError.lintFailed((lint.stdout + lint.stderr).replacingOccurrences(of: temp.path, with: url.lastPathComponent))
        }
        return temp
    }

    static func backupStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

extension Launchctl {
    /// Loads a saved plist, first unloading the job it replaces when that one is loaded.
    /// Returns every command it ran, for the activity log.
    /// - Parameter unloading: the label currently loaded (the old label if it was renamed), or nil.
    public func reload(unloading oldLabel: String?, plist url: URL, label: String) async throws -> [LaunchctlCommand] {
        var ran: [LaunchctlCommand] = []
        if let oldLabel {
            let bootout = bootoutCommand(label: oldLabel)
            ran.append(bootout)
            do {
                try await run(bootout, job: nil)
            } catch let failure as ActionFailure where failure.status == 3 || failure.status == Self.notFoundStatus {
                // Already gone; nothing to unload.
            }
        }
        let bootstrap = bootstrapCommand(plist: url, label: label)
        ran.append(bootstrap)
        do {
            try await run(bootstrap, job: nil)
        } catch let failure as ActionFailure where oldLabel != nil && (failure.status == 5 || failure.status == 37) {
            // A job that ignores SIGTERM can still be shutting down; give it a moment once.
            try await Task.sleep(for: .seconds(1))
            try await run(bootstrap, job: nil)
        }
        return ran
    }
}
