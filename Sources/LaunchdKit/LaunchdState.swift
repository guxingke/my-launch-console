import Foundation

/// How a job last exited, as launchd reports it.
public enum ExitStatus: Sendable, Equatable, Hashable {
    /// Never exited, or launchd shows `-`.
    case none
    case code(Int)
    /// Killed by a signal. launchd's services table shows these as negative codes (`-15`).
    case signal(Int)
    /// Anything launchd prints that isn't a number, e.g. `(jt)`.
    case other(String)

    init(launchd text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "-" || trimmed == "(never exited)" {
            self = .none
        } else if let code = Int(trimmed.prefix { $0 == "-" || $0.isNumber }) {
            self = code < 0 ? .signal(-code) : .code(code)
        } else {
            self = .other(trimmed)
        }
    }

    /// Signals that usually mean someone asked the job to stop, rather than that it broke.
    static let requestedStopSignals: Set<Int> = [1, 2, 15]  // HUP, INT, TERM

    static let signalNames: [Int: String] = [
        1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
        8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE", 15: "SIGTERM",
    ]

    public var isFailure: Bool {
        switch self {
        case .code(let code): code != 0
        case .signal(let signal): !Self.requestedStopSignals.contains(signal)
        case .none, .other: false
        }
    }

    public var description: String {
        switch self {
        case .none: "—"
        case .code(let code): String(code)
        case .signal(let signal): Self.signalNames[signal] ?? "signal \(signal)"
        case .other(let text): text
        }
    }
}

/// One row of the `services` table in `launchctl print <domain>`.
public struct ServiceEntry: Sendable, Equatable {
    public var label: String
    /// nil when not running (launchd prints 0).
    public var pid: Int?
    public var lastExit: ExitStatus

    public init(label: String, pid: Int?, lastExit: ExitStatus) {
        self.label = label
        self.pid = pid
        self.lastExit = lastExit
    }

    /// Parses `   71304      - \tlabel`.
    init?(tableLine line: String) {
        let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard parts.count == 3, let pid = Int(parts[0]) else { return nil }
        self.init(
            label: String(parts[2]).trimmingCharacters(in: .whitespaces),
            pid: pid > 0 ? pid : nil,
            lastExit: ExitStatus(launchd: String(parts[1]))
        )
    }
}

/// A persistent enable/disable override (`launchctl enable|disable`), stored outside the plist.
public enum Override: String, Sendable, Equatable {
    case enabled
    case disabled
}

/// Everything `launchctl print <domain>` tells us in one call.
public struct DomainSnapshot: Sendable, Equatable {
    public var domain: String
    public var services: [String: ServiceEntry]
    public var overrides: [String: Override]

    public init(domain: String, services: [String: ServiceEntry], overrides: [String: Override]) {
        self.domain = domain
        self.services = services
        self.overrides = overrides
    }

    public init?(parsing text: String) {
        guard let root = PrintParser.parse(text) else { return nil }
        var services: [String: ServiceEntry] = [:]
        for line in root.block("services")?.lines ?? [] {
            if let entry = ServiceEntry(tableLine: line) {
                services[entry.label] = entry
            }
        }
        var overrides: [String: Override] = [:]
        for field in root.block("disabled services")?.fields ?? [] {
            if let value = Override(rawValue: field.value) {
                overrides[field.key] = value
            }
        }
        self.init(domain: root.name, services: services, overrides: overrides)
    }
}

/// `launchctl print <domain>/<label>`: the full runtime picture of one loaded service.
public struct ServiceDetail: Sendable, Equatable {
    public var target: String
    /// The plist launchd loaded this from. nil when the service was submitted by another process.
    public var path: String?
    /// Who submitted it when there is no plist, e.g. `runningboardd.437`.
    public var submittedBy: String?
    public var type: String?
    public var state: String?
    public var jobState: String?
    public var program: String?
    public var arguments: [String]
    public var workingDirectory: String?
    public var pid: Int?
    public var runs: Int?
    public var lastExit: ExitStatus
    public var lastExitReason: String?
    public var lastSignal: String?
    public var spawnType: String?
    public var immediateReason: String?
    public var bundleID: String?
    public var stdoutPath: String?
    public var stderrPath: String?
    public var runInterval: String?
    public var properties: [String]
    public var environment: [String: String]
    public var raw: String

    public init?(parsing text: String) {
        guard let root = PrintParser.parse(text) else { return nil }
        target = root.name

        let path = root["path"]
        if let path, path.hasPrefix("(submitted by ") {
            self.path = nil
            submittedBy = String(path.dropFirst("(submitted by ".count).dropLast())
        } else {
            self.path = path
            submittedBy = nil
        }

        type = root["type"]
        state = root["state"]
        jobState = root["job state"]
        program = root["program"]
        arguments = root.block("arguments")?.lines ?? []
        workingDirectory = root["working directory"]
        pid = root["pid"].flatMap { Int($0) }
        runs = root["runs"].flatMap { Int($0) }
        lastExit = root["last exit code"].map(ExitStatus.init(launchd:)) ?? .none
        lastExitReason = root["last exit reason"]
        lastSignal = root["last terminating signal"]
        // After a signal death launchd prints `last terminating signal = Terminated: 15` instead of an exit code.
        if lastExit == .none, let lastSignal, let number = lastSignal.split(separator: ":").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            lastExit = .signal(number)
        }
        spawnType = root["spawn type"]
        immediateReason = root["immediate reason"]
        bundleID = root["bundle id"]
        stdoutPath = root["stdout path"]
        stderrPath = root["stderr path"]
        runInterval = root["run interval"]
        properties = (root["properties"] ?? "")
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        environment = root.block("environment")?.dictionary ?? [:]
        raw = text
    }

    public var keepAlive: Bool { properties.contains("keepalive") }
}
