import Foundation

/// The control verbs the app offers. Each maps to exactly one modern launchctl subcommand.
public enum JobAction: String, Sendable, CaseIterable, Identifiable {
    case start, restart, stop, load, unload, enable, disable

    public var id: Self { self }

    public var title: String {
        switch self {
        case .start: "Start"
        case .restart: "Restart"
        case .stop: "Stop"
        case .load: "Load"
        case .unload: "Unload"
        case .enable: "Enable"
        case .disable: "Disable"
        }
    }

    public var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .restart: "arrow.clockwise"
        case .stop: "stop.fill"
        case .load: "square.and.arrow.down"
        case .unload: "eject"
        case .enable: "checkmark.circle"
        case .disable: "nosign"
        }
    }

    /// Actions that end a running process or change what happens at next login.
    public var needsConfirmation: Bool {
        switch self {
        case .restart, .stop, .unload, .disable: true
        case .start, .load, .enable: false
        }
    }
}

/// A fully resolved launchctl invocation, so the UI can show exactly what will run.
public struct LaunchctlCommand: Sendable, Equatable {
    public var action: JobAction
    public var label: String
    public var arguments: [String]

    /// Copy-pasteable form, e.g. `launchctl kickstart -k gui/501/com.example.job`.
    public var shellString: String {
        (["launchctl"] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@+,")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum ActionPolicy {
    /// Why the app won't touch this job at all, or nil when some actions are allowed.
    public static func readOnlyReason(for job: Job) -> String? {
        if job.origin == .apple {
            return "Apple jobs are read-only."
        }
        if job.status == .staleOverride {
            return "Only a leftover override remains, so there's nothing to control."
        }
        if job.plist == nil, job.label.hasPrefix("application.") {
            return "This is a running app's own launchd entry. Quit or open the app instead."
        }
        return nil
    }

    /// The actions that make sense for the job's current state, in display order.
    public static func actions(for job: Job) -> [JobAction] {
        guard readOnlyReason(for: job) == nil else { return [] }
        var actions: [JobAction] = []
        if job.isLoaded {
            actions += job.pid == nil ? [.start] : [.restart, .stop]
            // Without a plist there'd be no way to load it back.
            if job.plist != nil { actions.append(.unload) }
        } else if let plist = job.plist, plist.error == nil, !job.isDisabled, job.loginItem?.isAllowed != false {
            // Switched off in Login Items means launchd refuses it until it's allowed there.
            actions.append(.load)
        }
        actions.append(job.isDisabled ? .enable : .disable)
        return actions
    }

    /// What the confirmation dialog says the action will do.
    public static func consequence(of action: JobAction, for job: Job) -> String {
        let keepsAlive = job.plist.map { $0.keepAlive != .off } ?? false
        switch action {
        case .start:
            return "Starts the job now."
        case .restart:
            return "Kills the running process and starts it again immediately."
        case .stop:
            return keepsAlive
                ? "Sends SIGTERM. This job has KeepAlive, so launchd will probably start it again right away. To keep it stopped, unload it."
                : "Sends SIGTERM to the running process. The job stays loaded and can start again on its next trigger."
        case .load:
            return "Loads the plist into this login session. If it has RunAtLoad, it starts now."
        case .unload:
            return job.isDisabled
                ? "Stops the job if it's running and removes it from launchd. It's disabled, so it won't come back at next login."
                : "Stops the job if it's running and removes it from launchd until next login. Disable it as well to keep it off."
        case .enable:
            return "Lets the job load at next login. It doesn't load it now; use Load for that."
        case .disable:
            return job.isLoaded
                ? "Stops the job from loading at next login. It stays loaded now; unload it to stop it immediately."
                : "Stops the job from loading at next login."
        }
    }
}

/// A launchctl failure, with the tool's own words plus a best guess at the cause.
public struct ActionFailure: Error, LocalizedError, Sendable, Equatable {
    public var command: LaunchctlCommand
    public var status: Int32
    /// launchctl's output, verbatim.
    public var output: String
    public var hint: String?

    public init(command: LaunchctlCommand, status: Int32, output: String, hint: String? = nil) {
        self.command = command
        self.status = status
        self.output = output
        self.hint = hint
    }

    public var errorDescription: String? {
        output.isEmpty ? "launchctl exited with status \(status)." : output
    }
}

extension Launchctl {
    public func command(for action: JobAction, on job: Job) -> LaunchctlCommand? {
        let target = target(job.label)
        let arguments: [String]
        switch action {
        case .start: arguments = ["kickstart", target]
        case .restart: arguments = ["kickstart", "-k", target]
        case .stop: arguments = ["kill", "SIGTERM", target]
        case .load:
            guard let path = job.plist?.url.path else { return nil }
            arguments = ["bootstrap", domain, path]
        case .unload: arguments = ["bootout", target]
        case .enable: arguments = ["enable", target]
        case .disable: arguments = ["disable", target]
        }
        return LaunchctlCommand(action: action, label: job.label, arguments: arguments)
    }

    /// `bootstrap` for a plist that may not be in the inventory yet (a newly created agent).
    public func bootstrapCommand(plist url: URL, label: String) -> LaunchctlCommand {
        LaunchctlCommand(action: .load, label: label, arguments: ["bootstrap", domain, url.path])
    }

    public func bootoutCommand(label: String) -> LaunchctlCommand {
        LaunchctlCommand(action: .unload, label: label, arguments: ["bootout", target(label)])
    }

    /// Runs the command. Throws `ActionFailure` with launchctl's own message when it fails.
    public func run(_ command: LaunchctlCommand, job: Job?) async throws {
        // The system domain needs root: one admin prompt per command, never a background helper.
        if domain == Launchctl.system.domain {
            try await PrivilegedLaunchctl.run(command, job: job)
            return
        }
        let result = try await Command.run(Self.executable, command.arguments)
        guard result.status != 0 else { return }
        let output = (result.stderr + result.stdout)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("Try re-running the command as root") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw ActionFailure(
            command: command,
            status: result.status,
            output: output,
            hint: Self.hint(for: command.action, status: result.status, job: job)
        )
    }

    /// launchctl's errors are terse; `bootstrap` reports "5: Input/output error" for several
    /// unrelated causes. Use what we know about the job to suggest the likely one.
    static func hint(for action: JobAction, status: Int32, job: Job?) -> String? {
        guard let job else {
            switch (action, status) {
            case (.load, 5): return "launchd rejected the plist. A job with the same label may already be loaded, or the label may be disabled."
            case (.unload, 3), (_, Launchctl.notFoundStatus): return "It isn't loaded (any more)."
            default: return nil
            }
        }
        switch (action, status) {
        case (.load, 5):
            if job.isLoaded { return "It's already loaded." }
            if job.isDisabled { return "It's disabled. Enable it first, then load it." }
            if let plist = job.plist, !FileManager.default.fileExists(atPath: plist.url.path) {
                return "The plist no longer exists."
            }
            return "launchd rejected the plist. Check it with: plutil -lint \(LaunchctlCommand.shellQuote(job.plist?.url.path ?? ""))"
        case (.stop, 3):
            return "It isn't running."
        case (.unload, 3), (_, Launchctl.notFoundStatus):
            return "It isn't loaded (any more)."
        case (_, 1) where !job.isLoaded:
            return "It isn't loaded."
        default:
            return nil
        }
    }
}
