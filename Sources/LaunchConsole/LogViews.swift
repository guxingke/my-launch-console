import AppKit
import LaunchdKit
import SwiftUI

/// The detail column: an Overview / Logs switch above the selected job.
struct JobInspector: View {
    let job: Job

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case logs = "Logs"
        var id: Self { self }
    }

    // Kept across selection changes, so you can flip through several jobs' logs.
    @State private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 8)
            #if DEBUG
            .onAppear { if let tab = DebugSnapshot.environment["LAUNCHCONSOLE_TAB"].flatMap(Tab.init(rawValue:)) { self.tab = tab } }
            #endif
            Divider()
            switch tab {
            case .overview: JobDetailView(job: job)
            case .logs: JobLogsView(job: job)
            }
        }
    }
}

enum LogSource: Hashable, Identifiable {
    /// launchd's own messages about the job.
    case launchd
    /// What the job's program writes to the unified log.
    case program
    /// A StandardOutPath / StandardErrorPath file.
    case file(String)

    var id: Self { self }

    var title: String {
        switch self {
        case .launchd: "launchd Events"
        case .program: "Program (Unified Log)"
        case .file(let path): (path as NSString).lastPathComponent
        }
    }

    static func available(for job: Job) -> [LogSource] {
        var sources: [LogSource] = [.launchd]
        if UnifiedLog.processPredicate(executable: job.plist?.executable, pid: job.pid) != nil {
            sources.append(.program)
        }
        var seen: Set<String> = []
        for path in [job.plist?.stdoutPath, job.plist?.stderrPath].compactMap({ $0 }) where seen.insert(path).inserted {
            sources.append(.file(path))
        }
        return sources
    }
}

enum HistoryWindow: Int, CaseIterable, Identifiable {
    case quarterHour = 900, hour = 3600, sixHours = 21600, day = 86400
    var id: Self { self }
    var title: String {
        switch self {
        case .quarterHour: "Last 15 Minutes"
        case .hour: "Last Hour"
        case .sixHours: "Last 6 Hours"
        case .day: "Last 24 Hours"
        }
    }
}

/// Loads a source's recent history, then keeps following it until cancelled.
@MainActor @Observable
final class LogFeed {
    static let maxEntries = 5000
    static let historyLimit = 2000

    private(set) var entries: [LogEntry] = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// The equivalent shell command, shown under the log.
    private(set) var command = ""
    private var nextID = 0

    func run(_ source: LogSource, job: Job, domain: String, history: HistoryWindow) async {
        entries = []
        error = nil
        isLoading = true
        defer { isLoading = false }

        switch source {
        case .launchd, .program:
            let predicate = source == .launchd
                ? UnifiedLog.launchdPredicate(domain: domain, label: job.label)
                : UnifiedLog.processPredicate(executable: job.plist?.executable, pid: job.pid)
            guard let predicate else {
                error = "Nothing specific to filter this job's program on."
                return
            }
            command = (["log"] + UnifiedLog.streamArguments(predicate: predicate)).map(LaunchctlCommand.shellQuote).joined(separator: " ")
            do {
                append(try await UnifiedLog.show(predicate: predicate, last: .seconds(history.rawValue), limit: Self.historyLimit))
            } catch {
                self.error = "Couldn't read the unified log: \(error.localizedDescription)"
            }
            isLoading = false
            do {
                for try await entry in UnifiedLog.stream(predicate: predicate) {
                    append([entry])
                }
            } catch {
                if !Task.isCancelled { self.error = "Log stream stopped: \(error.localizedDescription)" }
            }

        case .file(let path):
            command = "tail -f " + LaunchctlCommand.shellQuote(path)
            var tail = LogFileTail(url: URL(fileURLWithPath: path))
            do {
                append(try tail.readTail())
            } catch {
                self.error = FileManager.default.fileExists(atPath: path)
                    ? "Can't read \(path): \(error.localizedDescription)"
                    : "\(path) doesn't exist yet. launchd creates it the first time the job writes output."
            }
            isLoading = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let new = try? tail.readAppended(), !new.isEmpty {
                    append(new)
                    error = nil
                }
            }
        }
    }

    private func append(_ new: [LogEntry]) {
        for var entry in new {
            entry.id = nextID
            nextID += 1
            entries.append(entry)
        }
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
}

struct JobLogsView: View {
    let job: Job
    @Environment(JobStore.self) private var store
    @State private var feed = LogFeed()
    @State private var source: LogSource = .launchd
    @State private var history: HistoryWindow = .hour
    @State private var filter = ""
    @State private var keyEventsOnly = true
    @State private var follow = true

    private var sources: [LogSource] { LogSource.available(for: job) }

    private var isFileSource: Bool {
        if case .file = source { true } else { false }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let note { noteBanner(note) }
            if let error = feed.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            logList
            Divider()
            footer
        }
        .onChange(of: job.id) {
            if !sources.contains(source) { source = .launchd }
        }
        #if DEBUG
        .onAppear {
            switch DebugSnapshot.environment["LAUNCHCONSOLE_LOGSOURCE"] {
            case "program": source = .program
            case "file": source = sources.first { if case .file = $0 { true } else { false } } ?? source
            default: break
            }
        }
        #endif
        .task(id: "\(job.id)|\(source)|\(history.rawValue)") {
            await feed.run(sources.contains(source) ? source : .launchd, job: job, domain: job.domain, history: history)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Source", selection: $source) {
                ForEach(sources) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if !isFileSource {
                Picker("History", selection: $history) {
                    ForEach(HistoryWindow.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if source == .launchd {
                Toggle("Key events", isOn: $keyEventsOnly)
                    .toggleStyle(.checkbox)
                    .help("Hide launchd's internal state-change lines")
            }
            Spacer()
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
        }
        .controlSize(.small)
        .padding(8)
    }

    /// Explains when a job's output simply isn't captured anywhere.
    private var note: String? {
        guard source == .program, let plist = job.plist, plist.stdoutPath == nil, plist.stderrPath == nil else { return nil }
        return "This plist has no StandardOutPath or StandardErrorPath, so anything the program prints to stdout or stderr is discarded. Only what it sends to the unified log appears here."
    }

    private func noteBanner(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5))
    }

    private var visible: [LogEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return feed.entries.filter { entry in
            if source == .launchd, keyEventsOnly, !LogLine.isKeyLaunchdEvent(entry.message) { return false }
            return needle.isEmpty || entry.message.localizedCaseInsensitiveContains(needle)
        }
    }

    private var logList: some View {
        let rows = visible
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { entry in
                        // With every line shown, bold the ones that explain what happened.
                        LogLine(entry: entry, emphasize: source == .launchd && !keyEventsOnly && LogLine.isKeyLaunchdEvent(entry.message))
                            .id(entry.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if feed.isLoading {
                    ProgressView()
                } else if rows.isEmpty, feed.error == nil {
                    ContentUnavailableView(
                        "No Log Entries",
                        systemImage: "text.alignleft",
                        description: Text(filter.isEmpty ? "Nothing yet. New entries appear as they're written." : "Nothing matches the filter.")
                    )
                }
            }
            .onChange(of: rows.last?.id) { _, last in
                if follow, let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.checkbox)
            Text(feed.command)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(feed.command)
            Spacer()
            Text("\(visible.count) lines")
                .foregroundStyle(.secondary)
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(visible.map(LogLine.plainText).joined(separator: "\n"), forType: .string)
            }
            .help("Copy the visible lines")
            if case .file(let path) = source {
                Button("Reveal", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .help("Reveal the log file in Finder")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

struct LogLine: View {
    let entry: LogEntry
    var emphasize = false

    /// launchd lines that explain what happened to a job; the rest are internal state changes.
    static let keyPhrases = [
        "exited due to", "exited with", "Successfully spawned", "bootout initiated by", "removing service",
        "Pushing respawn", "deferred by", "Service only ran", "failed", "error", "crash", "signal", "service inactive",
    ]

    static func isKeyLaunchdEvent(_ message: String) -> Bool {
        keyPhrases.contains { message.localizedCaseInsensitiveContains($0) }
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func plainText(_ entry: LogEntry) -> String {
        guard let date = entry.date else { return entry.message }
        return "\(timeFormatter.string(from: date))  \(entry.message)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let date = entry.date {
                Text(Self.timeFormatter.string(from: date))
                    .foregroundStyle(.secondary)
            }
            if entry.level == .error || entry.level == .fault {
                Text(entry.level.rawValue.uppercased())
                    .foregroundStyle(.red)
            }
            Text(entry.message)
                .fontWeight(emphasize ? .semibold : .regular)
                .foregroundStyle(entry.level == .error || entry.level == .fault ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
    }
}
