import Foundation

public enum JobStatus: String, Sendable, CaseIterable, Comparable {
    case running
    /// Loaded, not running, last exit non-zero.
    case failing
    /// Loaded and waiting for its trigger (or finished cleanly).
    case idle
    /// A plist exists but launchd hasn't loaded it.
    case notLoaded
    case disabled
    /// Only an entry in the override database remains; no plist, not loaded.
    case staleOverride

    public var title: String {
        switch self {
        case .running: "Running"
        case .failing: "Failing"
        case .idle: "Idle"
        case .notLoaded: "Not loaded"
        case .disabled: "Disabled"
        case .staleOverride: "Leftover override"
        }
    }

    public static func < (lhs: JobStatus, rhs: JobStatus) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Something worth pointing out about a job, typically a disagreement between the plist,
/// what launchd has loaded, and the override database.
public enum Issue: Sendable, Equatable, Hashable {
    public enum Severity: Int, Sendable, Comparable {
        case info, warning, error
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    case lastExitFailed(ExitStatus)
    case crashLoop(runs: Int)
    case loadedButDisabled
    case keepAliveNotRunning
    case shouldBeLoaded
    case plistUnreadable(String)
    case labelDiffersFromFilename(fileName: String)
    case duplicateDefinition(path: String)
    case loadedPlistMissing(path: String)
    case loadedConfigDiffers
    case staleOverride(Override)
    case blockedInLoginItems(app: String?)

    public var severity: Severity {
        switch self {
        case .crashLoop, .plistUnreadable: .error
        case .lastExitFailed, .keepAliveNotRunning, .shouldBeLoaded, .loadedPlistMissing, .loadedConfigDiffers, .duplicateDefinition: .warning
        case .loadedButDisabled, .labelDiffersFromFilename, .staleOverride, .blockedInLoginItems: .info
        }
    }

    public var message: String {
        switch self {
        case .lastExitFailed(.signal(let signal)):
            "Last run was killed by \(ExitStatus.signal(signal).description)."
        case .lastExitFailed(let status):
            "Last run exited with code \(status.description)."
        case .crashLoop(let runs):
            "Crash loop: launchd has started it \(runs.formatted()) times and it keeps exiting with an error."
        case .loadedButDisabled:
            "Disabled, but still loaded in this session. It won't load at next login."
        case .keepAliveNotRunning:
            "KeepAlive is on, but it isn't running. launchd should have restarted it."
        case .shouldBeLoaded:
            "Not loaded now, but it will load at next login (RunAtLoad or KeepAlive). Disable it to keep it off."
        case .plistUnreadable(let error):
            "The plist can't be read: \(error)"
        case .labelDiffersFromFilename(let fileName):
            "Label doesn't match the file name (\(fileName))."
        case .duplicateDefinition(let path):
            "The same label is also defined in \(path)."
        case .loadedPlistMissing(let path):
            "Loaded from \(path), which no longer exists."
        case .loadedConfigDiffers:
            "The plist on disk differs from what launchd loaded. It was edited after loading; reload to apply."
        case .blockedInLoginItems(let app):
            "Switched off in System Settings → General → Login Items & Extensions\(app.map { " (under \($0))" } ?? ""). launchd won't load it until it's allowed there."
        case .staleOverride(let value):
            "Only a leftover \(value.rawValue) override remains; the job itself is gone."
        }
    }
}

/// One job, joined from the three places launchd state lives: the plist on disk,
/// the loaded service, and the override database. Any of the three may be missing.
public struct Job: Identifiable, Sendable, Equatable {
    /// The launchctl target, e.g. `gui/501/com.example.job` or `system/com.example.daemon`,
    /// so the same label can exist in both domains.
    public var id: String { domain.isEmpty ? label : "\(domain)/\(label)" }
    public var label: String
    public var origin: Origin
    public var plist: PlistJob?
    public var service: ServiceEntry?
    public var override: Override?
    /// What System Settings → Login Items says about it, when it tracks this job.
    public var loginItem: LoginItemInfo? = nil
    public var status: JobStatus
    public var issues: [Issue]
    /// `gui/<uid>` or `system`.
    public var domain = ""

    public var isLoaded: Bool { service != nil }
    /// A LaunchDaemon in the system domain: runs as root, needs admin rights to control.
    public var isSystem: Bool { domain == "system" }
    public var pid: Int? { service?.pid }

    /// Disabled per the override database, or per the plist's own key when there's no override.
    public var isDisabled: Bool {
        switch override {
        case .disabled: true
        case .enabled: false
        case nil: plist?.disabledKey ?? false
        }
    }

    public var worstSeverity: Issue.Severity? {
        issues.map(\.severity).max()
    }
}

public enum Inventory {
    /// Joins a domain snapshot with the plists on disk. Pure, so it's easy to test.
    public static func build(snapshot: DomainSnapshot, plists: [PlistJob], loginItems: [String: LoginItemInfo] = [:]) -> [Job] {
        var plistByLabel: [String: PlistJob] = [:]
        var duplicates: [String: [String]] = [:]
        // Directory order is user → global → apple, so the first definition wins.
        for plist in plists {
            let label = plist.effectiveLabel
            if plistByLabel[label] == nil {
                plistByLabel[label] = plist
            } else {
                duplicates[label, default: []].append(plist.url.path)
            }
        }

        let labels = Set(plistByLabel.keys)
            .union(snapshot.services.keys)
            .union(snapshot.overrides.keys)

        return labels.map { label in
            let plist = plistByLabel[label]
            var job = Job(
                label: label,
                origin: plist?.origin ?? origin(forUnfiledLabel: label),
                plist: plist,
                service: snapshot.services[label],
                override: snapshot.overrides[label],
                loginItem: loginItems[label],
                status: .idle,
                issues: [],
                domain: snapshot.domain
            )
            job.status = status(of: job)
            job.issues = issues(of: job, duplicates: duplicates[label] ?? [])
            return job
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func origin(forUnfiledLabel label: String) -> Origin {
        label.hasPrefix("com.apple.") ? .apple : .app
    }

    static func status(of job: Job) -> JobStatus {
        if let service = job.service {
            if service.pid != nil { return .running }
            return service.lastExit.isFailure ? .failing : .idle
        }
        if job.plist != nil {
            return job.isDisabled ? .disabled : .notLoaded
        }
        return .staleOverride
    }

    static func issues(of job: Job, duplicates: [String]) -> [Issue] {
        var issues: [Issue] = []
        if let plist = job.plist {
            if let error = plist.error {
                issues.append(.plistUnreadable(error))
            }
            let fileName = plist.url.deletingPathExtension().lastPathComponent
            if let label = plist.label, label != fileName, job.origin != .apple {
                issues.append(.labelDiffersFromFilename(fileName: plist.url.lastPathComponent))
            }
            let wantsToRun = plist.runAtLoad || plist.keepAlive != .off
            if job.loginItem?.isAllowed == false {
                // This explains why it isn't loaded, so "should be loaded" would only add noise.
                issues.append(.blockedInLoginItems(app: job.loginItem?.appName))
            } else if !job.isLoaded, !job.isDisabled, wantsToRun, plist.loadsInGUISession, plist.error == nil, job.origin != .apple {
                issues.append(.shouldBeLoaded)
            }
        }
        for path in duplicates {
            issues.append(.duplicateDefinition(path: path))
        }
        if let service = job.service {
            if service.pid == nil, service.lastExit.isFailure {
                issues.append(.lastExitFailed(service.lastExit))
            } else if service.pid == nil, job.plist?.keepAlive == .always, !job.isDisabled {
                // A failing exit already explains the gap; this is for jobs that stopped quietly.
                issues.append(.keepAliveNotRunning)
            }
            if job.override == .disabled {
                issues.append(.loadedButDisabled)
            }
        }
        if job.status == .staleOverride, let override = job.override {
            issues.append(.staleOverride(override))
        }
        return issues
    }
}

public enum Diagnostics {
    /// launchd restarts KeepAlive jobs at most every ~10 s, so this many runs with a failing
    /// last exit means it has been looping for a while rather than failing once.
    public static let crashLoopRuns = 10

    /// Issues that need the per-service detail (`launchctl print <target>`), not just the list.
    public static func detailIssues(
        for job: Job,
        detail: ServiceDetail,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [Issue] {
        var issues: [Issue] = []
        if let runs = detail.runs, runs >= crashLoopRuns, detail.lastExit.isFailure, detail.keepAlive {
            issues.append(.crashLoop(runs: runs))
        }
        if let path = detail.path, path.hasPrefix("/"), !fileExists(path) {
            issues.append(.loadedPlistMissing(path: path))
        }
        if let plist = job.plist, plist.error == nil, job.origin != .apple, configDiffers(plist: plist, detail: detail) {
            issues.append(.loadedConfigDiffers)
        }
        return issues
    }

    static func configDiffers(plist: PlistJob, detail: ServiceDetail) -> Bool {
        let loaded = detail.arguments.isEmpty ? detail.program.map { [$0] } ?? [] : detail.arguments
        let onDisk = plist.commandLine
        guard !loaded.isEmpty, !onDisk.isEmpty else { return false }
        if loaded != onDisk { return true }
        if let program = plist.program, let loadedProgram = detail.program, program != loadedProgram { return true }
        return false
    }
}
