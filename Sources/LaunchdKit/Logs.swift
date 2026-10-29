import Foundation

/// One line of log output, from the unified log or a job's output file.
public struct LogEntry: Sendable, Equatable, Identifiable {
    public enum Level: String, Sendable {
        case debug, info, `default`, error, fault
    }

    public var id: Int
    /// nil for lines read from an output file, which carry no timestamp of their own.
    public var date: Date?
    public var level: Level
    public var process: String?
    public var pid: Int?
    public var subsystem: String?
    public var message: String

    public init(id: Int, date: Date? = nil, level: Level = .default, process: String? = nil, pid: Int? = nil, subsystem: String? = nil, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.process = process
        self.pid = pid
        self.subsystem = subsystem
        self.message = message
    }
}

/// Reads the unified log through `/usr/bin/log`, the same data Console.app shows.
public enum UnifiedLog {
    public static let executable = "/usr/bin/log"

    /// launchd's own messages about a job: spawns, exits, throttling, and who booted it out.
    /// launchd tags them with the subsystem `<domain>/<label>`, plus ` [pid]` while running.
    public static func launchdPredicate(domain: String, label: String) -> String {
        let target = quote("\(domain)/\(label)")
        let targetWithPID = quote("\(domain)/\(label) [")
        return "process == \"launchd\" AND (subsystem == \(target) OR subsystem BEGINSWITH \(targetWithPID) OR eventMessage CONTAINS \(quote(label)))"
    }

    /// Generic interpreters run many unrelated jobs, so filter those by PID rather than name.
    static let sharedExecutables: Set<String> = ["sh", "bash", "zsh", "dash", "env", "python", "python3", "node", "ruby", "perl", "osascript", "java"]

    /// What the job's program itself logs. nil when there's nothing specific to filter on.
    public static func processPredicate(executable: String?, pid: Int?) -> String? {
        if let executable {
            let name = (executable as NSString).lastPathComponent
            if !sharedExecutables.contains(name) {
                return "process == \(quote(name))"
            }
        }
        return pid.map { "processIdentifier == \($0)" }
    }

    /// NSPredicate string literal with escaping.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func showArguments(predicate: String, last: Duration) -> [String] {
        ["show", "--style", "ndjson", "--last", "\(Int(last.components.seconds))s", "--predicate", predicate]
    }

    public static func streamArguments(predicate: String) -> [String] {
        ["stream", "--style", "ndjson", "--predicate", predicate]
    }

    /// Recent history, oldest first, keeping at most `limit` of the newest entries.
    public static func show(predicate: String, last: Duration, limit: Int = 1000) async throws -> [LogEntry] {
        let result = try await Command.run(executable, showArguments(predicate: predicate, last: last))
        guard result.status == 0 else {
            throw LaunchctlError(command: "log show", status: result.status, output: result.stderr)
        }
        let entries = parse(ndjson: result.stdout)
        return Array(entries.suffix(limit))
    }

    /// Follows the log until the consuming task is cancelled.
    public static func stream(predicate: String) -> AsyncThrowingStream<LogEntry, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = streamArguments(predicate: predicate)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            let reader = Task {
                var counter = 0
                do {
                    for try await line in pipe.fileHandleForReading.bytes.lines {
                        if let entry = parse(line: line, id: counter) {
                            counter += 1
                            continuation.yield(entry)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                runningStreams.remove(process)
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
                runningStreams.insert(process)
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// `log stream` children outlive the app if it exits without cancelling them, and one
    /// following a quiet process never writes, so it never hits a broken pipe. Call on quit.
    public static func terminateAllStreams() {
        runningStreams.terminateAll()
    }

    private static let runningStreams = ProcessSet()

    static var runningStreamCount: Int { runningStreams.count }
}

private final class ProcessSet: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func insert(_ process: Process) {
        lock.withLock { processes[ObjectIdentifier(process)] = process }
    }

    func remove(_ process: Process) {
        lock.withLock { _ = processes.removeValue(forKey: ObjectIdentifier(process)) }
    }

    var count: Int {
        lock.withLock { processes.values.filter(\.isRunning).count }
    }

    func terminateAll() {
        let all = lock.withLock { processes.values }
        for process in all where process.isRunning {
            process.terminate()
        }
    }
}

extension UnifiedLog {
    public static func parse(ndjson text: String) -> [LogEntry] {
        var entries: [LogEntry] = []
        for line in text.split(separator: "\n") {
            if let entry = parse(line: String(line), id: entries.count) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Parses one ndjson line. Skips headers ("Filtering the log data…"), the trailing
    /// `{"count":…,"finished":1}` summary, and activity records without a message.
    static func parse(line: String, id: Int) -> LogEntry? {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["eventMessage"] as? String else { return nil }
        let level: LogEntry.Level = switch (object["messageType"] as? String)?.lowercased() {
        case "debug": .debug
        case "info": .info
        case "error": .error
        case "fault": .fault
        default: .default
        }
        let subsystem = (object["subsystem"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return LogEntry(
            id: id,
            date: (object["timestamp"] as? String).flatMap(parseTimestamp),
            level: level,
            process: (object["processImagePath"] as? String).map { ($0 as NSString).lastPathComponent },
            pid: object["processID"] as? Int,
            subsystem: subsystem,
            message: message
        )
    }

    /// `2026-10-28 05:18:46.378797-0400`. DateFormatter keeps millisecond precision, which is plenty.
    static func parseTimestamp(_ text: String) -> Date? {
        timestampFormatter.date(from: text)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()
}

/// Reads the end of a job's StandardOutPath / StandardErrorPath and picks up what's appended.
public struct LogFileTail: Sendable {
    public var url: URL
    /// Byte offset read up to so far.
    public private(set) var offset: UInt64 = 0
    /// Bytes of a final line that hasn't ended yet.
    private var partial = Data()
    private var nextID = 0

    public init(url: URL) {
        self.url = url
    }

    /// The last `maxBytes` of the file, dropping a cut-off first line. Resets any previous position.
    public mutating func readTail(maxBytes: Int = 64 * 1024) throws -> [LogEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        offset = start + UInt64(data.count)
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[data.index(after: newline)...]
        }
        partial = Data()
        return lines(from: data)
    }

    /// Lines appended since the last read. If the file shrank (truncated or rotated), starts over from the top.
    public mutating func readAppended() throws -> [LogEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size < offset {
            offset = 0
            partial = Data()
        }
        guard size > offset else { return [] }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        offset += UInt64(data.count)
        return lines(from: data)
    }

    /// Programs that think they're writing to a terminal leave colour codes like `ESC[32m` in their logs.
    static func stripANSI(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        return line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private mutating func lines(from data: Data) -> [LogEntry] {
        var buffer = partial + data
        var entries: [LogEntry] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            entries.append(LogEntry(id: nextID, message: Self.stripANSI(line)))
            nextID += 1
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        partial = buffer
        return entries
    }
}
