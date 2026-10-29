import Foundation
import Testing
@testable import LaunchdKit

private func ndjsonFixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "ndjson", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct UnifiedLogTests {
    @Test func parsesLaunchdHistoryForAJob() throws {
        // Real `log show --style ndjson` output for sing-box's last crash and its bootout.
        let entries = UnifiedLog.parse(ndjson: try ndjsonFixture("unifiedlog-launchd"))
        #expect(entries.count == 28)
        #expect(entries.allSatisfy { $0.process == "launchd" && $0.pid == 1 })
        #expect(entries.contains { $0.message == "exited due to exit(1), ran for 163ms" })
        #expect(entries.contains { $0.message.hasPrefix("bootout initiated by: launchctl[") })
        #expect(entries.first?.subsystem == "gui/501/homebrew.mxcl.sing-box")

        let first = try #require(entries.first?.date)
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: -4 * 3600)!, from: first)
        #expect(components.hour == 5 && components.minute == 18 && components.second == 36)
    }

    @Test func skipsHeadersSummariesAndActivityRecords() throws {
        let text = """
        Filtering the log data using "process == "launchd""
        {"eventType":"activityCreateEvent","processID":7,"timestamp":"2026-10-28 05:18:16.695000-0400"}
        {"eventType":"logEvent","messageType":"Error","eventMessage":"boom","processID":7,"processImagePath":"/usr/bin/x","subsystem":"","timestamp":"2026-10-28 05:18:16.695000-0400"}
        {"count":2,"finished":1}
        """
        let entries = UnifiedLog.parse(ndjson: text)
        #expect(entries.count == 1)
        #expect(entries[0].level == .error)
        #expect(entries[0].process == "x")
        #expect(entries[0].subsystem == nil)
    }

    @Test func toleratesRealProcessOutputWithoutMessageType() throws {
        // The program's own records from the same crash; some lack `messageType`.
        let entries = UnifiedLog.parse(ndjson: try ndjsonFixture("unifiedlog-process"))
        #expect(entries.allSatisfy { $0.process == "sing-box" })
    }

    @Test func buildsPredicates() {
        #expect(UnifiedLog.launchdPredicate(domain: "gui/501", label: "a.b") ==
            #"process == "launchd" AND (subsystem == "gui/501/a.b" OR subsystem BEGINSWITH "gui/501/a.b [" OR eventMessage CONTAINS "a.b")"#)
        #expect(UnifiedLog.processPredicate(executable: "/opt/homebrew/opt/sing-box/bin/sing-box", pid: nil) == #"process == "sing-box""#)
        #expect(UnifiedLog.processPredicate(executable: "/bin/sh", pid: 42) == "processIdentifier == 42")
        #expect(UnifiedLog.processPredicate(executable: "/bin/sh", pid: nil) == nil)
        #expect(UnifiedLog.quote(#"say "hi" \o/"#) == #""say \"hi\" \\o/""#)
    }

    @Test func buildsCommandLines() {
        #expect(UnifiedLog.showArguments(predicate: "p", last: .seconds(3600)) == ["show", "--style", "ndjson", "--last", "3600s", "--predicate", "p"])
        #expect(UnifiedLog.streamArguments(predicate: "p") == ["stream", "--style", "ndjson", "--predicate", "p"])
    }
}

@Suite struct LogFileTailTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func tailsFollowsAndHandlesPartialLines() throws {
        let url = dir.appending(path: "out.log")
        try Data("one\ntwo\nthr".utf8).write(to: url)
        var tail = LogFileTail(url: url)

        #expect(try tail.readTail().map(\.message) == ["one", "two"])
        #expect(try tail.readAppended().isEmpty)

        try append("ee\nfour\n", to: url)
        #expect(try tail.readAppended().map(\.message) == ["three", "four"])
    }

    @Test func dropsCutOffFirstLineWhenTailing() throws {
        let url = dir.appending(path: "big.log")
        try Data((1...100).map { "line \($0)\n" }.joined().utf8).write(to: url)
        var tail = LogFileTail(url: url)
        let lines = try tail.readTail(maxBytes: 40).map(\.message)
        #expect(lines.last == "line 100")
        #expect(lines.allSatisfy { $0.hasPrefix("line ") })
        #expect(lines.count < 5)
    }

    @Test func restartsAfterTruncation() throws {
        let url = dir.appending(path: "rotated.log")
        try Data("old 1\nold 2\n".utf8).write(to: url)
        var tail = LogFileTail(url: url)
        _ = try tail.readTail()

        try Data("new\n".utf8).write(to: url)
        #expect(try tail.readAppended().map(\.message) == ["new"])
    }

    @Test func missingFileThrows() {
        var tail = LogFileTail(url: dir.appending(path: "nope.log"))
        #expect(throws: (any Error).self) { try tail.readTail() }
    }
}

@Suite struct KeepAliveHealthTests {
    private func job(lastExit: LaunchdKit.ExitStatus, pid: Int?, keepAlive: KeepAlive) -> Job {
        var plist = PlistJob(url: URL(fileURLWithPath: "/Users/me/Library/LaunchAgents/x.plist"), origin: .user)
        plist.label = "x"
        plist.keepAlive = keepAlive
        let snapshot = DomainSnapshot(domain: "gui/501", services: ["x": ServiceEntry(label: "x", pid: pid, lastExit: lastExit)], overrides: [:])
        return Inventory.build(snapshot: snapshot, plists: [plist])[0]
    }

    @Test func flagsQuietlyStoppedKeepAliveJob() {
        #expect(job(lastExit: .code(0), pid: nil, keepAlive: .always).issues == [.keepAliveNotRunning])
    }

    @Test func failingExitTakesPrecedence() {
        #expect(job(lastExit: .code(1), pid: nil, keepAlive: .always).issues == [.lastExitFailed(.code(1))])
    }

    @Test func runningOrConditionalIsFine() {
        #expect(job(lastExit: .none, pid: 5, keepAlive: .always).issues.isEmpty)
        #expect(job(lastExit: .code(0), pid: nil, keepAlive: .conditional(["SuccessfulExit"])).issues.isEmpty)
    }
}

/// Runs the real `/usr/bin/log stream` (read-only) to check its child process doesn't outlive the consumer.
@Suite(.serialized) struct UnifiedLogStreamTests {
    @Test func cancellingTheConsumerStopsTheChildProcess() async throws {
        let consumer = Task {
            for try await _ in UnifiedLog.stream(predicate: #"process == "launchconsole-no-such-process""#) {}
        }
        try await Task.sleep(for: .seconds(1))
        #expect(UnifiedLog.runningStreamCount == 1)
        consumer.cancel()
        try await Task.sleep(for: .milliseconds(500))
        #expect(UnifiedLog.runningStreamCount == 0)
    }

    @Test func terminateAllStopsOrphanedStreams() async throws {
        let consumer = Task {
            for try await _ in UnifiedLog.stream(predicate: #"process == "launchconsole-no-such-process""#) {}
        }
        try await Task.sleep(for: .seconds(1))
        UnifiedLog.terminateAllStreams()
        try await Task.sleep(for: .milliseconds(500))
        #expect(UnifiedLog.runningStreamCount == 0)
        consumer.cancel()
    }
}

@Suite struct ANSITests {
    @Test func stripsColourCodes() {
        #expect(LogFileTail.stripANSI("--> GET /api [33m401[0m 1ms".replacingOccurrences(of: "[", with: "\u{1B}[")) == "--> GET /api 401 1ms")
        #expect(LogFileTail.stripANSI("plain [brackets]") == "plain [brackets]")
    }
}
