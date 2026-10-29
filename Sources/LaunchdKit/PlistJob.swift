import Foundation

/// Where a job comes from. Drives default visibility and, later, what the app lets you change.
public enum Origin: String, Sendable, CaseIterable, Comparable {
    /// `~/Library/LaunchAgents`
    case user
    /// `/Library/LaunchAgents`: installed by third-party software for every user.
    case global
    /// Registered at runtime by an app (SMAppService, `application.*` jobs); no plist in the agent dirs.
    case app
    /// `/System/Library/LaunchAgents` or a `com.apple.*` label.
    case apple

    public var title: String {
        switch self {
        case .user: "User"
        case .global: "Third-party"
        case .app: "App-registered"
        case .apple: "Apple"
        }
    }

    public static func < (lhs: Origin, rhs: Origin) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum KeepAlive: Sendable, Equatable {
    case off
    case always
    /// Dictionary form; keys such as `SuccessfulExit`, `NetworkState`, `PathState`.
    case conditional([String])
}

/// A launchd job definition read from a plist on disk.
public struct PlistJob: Sendable, Equatable {
    public var url: URL
    public var origin: Origin
    public var modified: Date?
    /// Why the file couldn't be used, if it couldn't.
    public var error: String?

    public var label: String?
    public var program: String?
    public var programArguments: [String] = []
    public var runAtLoad = false
    public var keepAlive: KeepAlive = .off
    public var startInterval: Int?
    public var calendarIntervals: [[String: Int]] = []
    public var watchPaths: [String] = []
    public var stdoutPath: String?
    public var stderrPath: String?
    public var workingDirectory: String?
    /// The plist's own `Disabled` key. An override in launchd's database takes precedence.
    public var disabledKey = false
    public var sessionTypes: [String] = []
    public var environment: [String: String] = [:]
    public var associatedBundleIDs: [String] = []
    /// The file as XML, for the raw view.
    public var xml: String?

    public init(url: URL, origin: Origin, modified: Date? = nil) {
        self.url = url
        self.origin = origin
        self.modified = modified
    }

    public static func load(url: URL, origin: Origin, modified: Date? = nil) -> PlistJob {
        var job = PlistJob(url: url, origin: origin, modified: modified)
        let plist: Any
        do {
            let data = try Data(contentsOf: url)
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path),
               !FileManager.default.fileExists(atPath: url.path) {
                job.error = "Broken symlink to \(target). Whatever installed it was probably removed."
            } else {
                job.error = error.localizedDescription
            }
            return job
        }
        guard let dict = plist as? [String: Any] else {
            job.error = "Top level is not a dictionary"
            return job
        }
        job.apply(dict)
        if let xmlData = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            job.xml = String(decoding: xmlData, as: UTF8.self)
        }
        return job
    }

    mutating func apply(_ dict: [String: Any]) {
        label = dict["Label"] as? String
        program = dict["Program"] as? String
        programArguments = dict["ProgramArguments"] as? [String] ?? []
        runAtLoad = dict["RunAtLoad"] as? Bool ?? false
        switch dict["KeepAlive"] {
        case let value as Bool: keepAlive = value ? .always : .off
        case let value as [String: Any]: keepAlive = .conditional(value.keys.sorted())
        default: keepAlive = .off
        }
        startInterval = dict["StartInterval"] as? Int
        switch dict["StartCalendarInterval"] {
        case let one as [String: Int]: calendarIntervals = [one]
        case let many as [[String: Int]]: calendarIntervals = many
        default: calendarIntervals = []
        }
        watchPaths = dict["WatchPaths"] as? [String] ?? []
        stdoutPath = dict["StandardOutPath"] as? String
        stderrPath = dict["StandardErrorPath"] as? String
        workingDirectory = dict["WorkingDirectory"] as? String
        disabledKey = dict["Disabled"] as? Bool ?? false
        switch dict["LimitLoadToSessionType"] {
        case let one as String: sessionTypes = [one]
        case let many as [String]: sessionTypes = many
        default: sessionTypes = []
        }
        environment = dict["EnvironmentVariables"] as? [String: String] ?? [:]
        associatedBundleIDs = dict["AssociatedBundleIdentifiers"] as? [String]
            ?? (dict["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
    }

    /// The label launchd will use: the `Label` key, falling back to the file name.
    public var effectiveLabel: String {
        label ?? url.deletingPathExtension().lastPathComponent
    }

    /// The command line launchd runs: `ProgramArguments`, with `Program` overriding argv[0]'s path.
    public var commandLine: [String] {
        if programArguments.isEmpty { return program.map { [$0] } ?? [] }
        return programArguments
    }

    public var executable: String? {
        program ?? programArguments.first
    }

    /// Whether launchd loads this into a GUI (Aqua) login session.
    public var loadsInGUISession: Bool {
        sessionTypes.isEmpty || sessionTypes.contains("Aqua")
    }
}

/// Reads the agent directories, re-parsing only files whose modification date changed.
/// Not thread-safe: own it from a single actor.
public final class PlistCatalog {
    public struct Directory: Sendable {
        public var url: URL
        public var origin: Origin

        public init(url: URL, origin: Origin) {
            self.url = url
            self.origin = origin
        }
    }

    /// The directories whose agents load into a user's GUI session.
    public static func userDomainDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Directory] {
        [
            Directory(url: home.appending(path: "Library/LaunchAgents"), origin: .user),
            Directory(url: URL(fileURLWithPath: "/Library/LaunchAgents"), origin: .global),
            Directory(url: URL(fileURLWithPath: "/System/Library/LaunchAgents"), origin: .apple),
        ]
    }

    /// The directories whose daemons load into the system domain.
    public static let systemDomainDirectories: [Directory] = [
        Directory(url: URL(fileURLWithPath: "/Library/LaunchDaemons"), origin: .global),
        Directory(url: URL(fileURLWithPath: "/System/Library/LaunchDaemons"), origin: .apple),
    ]

    private var cache: [URL: PlistJob] = [:]
    public let directories: [Directory]

    public init(directories: [Directory] = PlistCatalog.userDomainDirectories()) {
        self.directories = directories
    }

    public func scan() -> [PlistJob] {
        var seen: [URL: PlistJob] = [:]
        var result: [PlistJob] = []
        for directory in directories {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory.url,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls.sorted(by: { $0.path < $1.path }) where url.pathExtension == "plist" {
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let job: PlistJob
                if let cached = cache[url], cached.modified == modified, cached.origin == directory.origin {
                    job = cached
                } else {
                    job = PlistJob.load(url: url, origin: directory.origin, modified: modified)
                }
                seen[url] = job
                result.append(job)
            }
        }
        cache = seen
        return result
    }
}
