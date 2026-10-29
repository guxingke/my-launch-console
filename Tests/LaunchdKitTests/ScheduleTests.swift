import Foundation
import Testing
@testable import LaunchdKit

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

/// A local New York time.
private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    newYork.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite struct ScheduleTests {
    // 2026-10-29 is a Thursday.
    let now = at(2026, 10, 29, 10, 30)

    @Test func dailyAtAFixedTime() {
        #expect(Schedule.nextFire(["Hour": 9, "Minute": 0], after: now, calendar: newYork) == at(2026, 10, 30, 9, 0))
        #expect(Schedule.nextFire(["Hour": 12, "Minute": 38], after: now, calendar: newYork) == at(2026, 10, 29, 12, 38))
    }

    @Test func strictlyAfter() {
        #expect(Schedule.nextFire(["Hour": 10, "Minute": 30], after: now, calendar: newYork) == at(2026, 10, 30, 10, 30))
    }

    @Test func wildcards() {
        #expect(Schedule.nextFire(["Minute": 15], after: now, calendar: newYork) == at(2026, 10, 29, 11, 15))
        #expect(Schedule.nextFire([:], after: now, calendar: newYork) == at(2026, 10, 29, 10, 31))
        #expect(Schedule.nextFire(["Hour": 3], after: now, calendar: newYork) == at(2026, 10, 30, 3, 0))
    }

    @Test func weekdaysWithSundayAsZeroOrSeven() {
        let sunday = at(2026, 11, 1, 9, 0)
        #expect(Schedule.nextFire(["Weekday": 0, "Hour": 9, "Minute": 0], after: now, calendar: newYork) == sunday)
        #expect(Schedule.nextFire(["Weekday": 7, "Hour": 9, "Minute": 0], after: now, calendar: newYork) == sunday)
        #expect(Schedule.nextFire(["Weekday": 1, "Hour": 9, "Minute": 0], after: now, calendar: newYork) == at(2026, 11, 2, 9, 0))
    }

    @Test func dayAndWeekdayMatchEitherLikeCron() {
        // Day 1 or any Monday: Monday Nov 2 comes after Sunday Nov 1.
        let rule = ["Day": 1, "Weekday": 1, "Hour": 0, "Minute": 0]
        let first = Schedule.nextFire(rule, after: now, calendar: newYork)
        #expect(first == at(2026, 11, 1))
        #expect(Schedule.nextFire(rule, after: first!, calendar: newYork) == at(2026, 11, 2))
    }

    @Test func rareDates() {
        #expect(Schedule.nextFire(["Month": 2, "Day": 29, "Hour": 0, "Minute": 0], after: now, calendar: newYork) == at(2028, 2, 29))
        #expect(Schedule.nextFire(["Month": 2, "Day": 30], after: now, calendar: newYork) == nil)
        #expect(Schedule.nextFire(["Hour": 25], after: now, calendar: newYork) == nil)
    }

    @Test func calendarFiresMergeEntries() {
        let fires = Schedule.calendarFires(
            [["Hour": 9, "Minute": 0], ["Hour": 21, "Minute": 0]],
            from: now, to: at(2026, 10, 31), calendar: newYork
        )
        #expect(fires == [at(2026, 10, 29, 21), at(2026, 10, 30, 9), at(2026, 10, 30, 21)])
    }

    @Test func intervalFiresProjectFromTheLastRun() {
        let last = at(2026, 10, 29, 10, 16)
        let fires = Schedule.intervalFires(seconds: 3600, lastRun: last, from: now, to: at(2026, 10, 29, 13, 30))
        #expect(fires == [at(2026, 10, 29, 11, 16), at(2026, 10, 29, 12, 16), at(2026, 10, 29, 13, 16)])
        // A last run long ago still lands on the same phase.
        let old = Schedule.intervalFires(seconds: 3600, lastRun: at(2026, 10, 20, 0, 16), from: now, to: at(2026, 10, 29, 11, 30))
        #expect(old == [at(2026, 10, 29, 11, 16)])
        #expect(Schedule.intervalFires(seconds: 3600, lastRun: nil, from: now, to: at(2026, 10, 30)).isEmpty)
    }

    @Test func rulesFromPlist() {
        var plist = PlistJob(url: URL(fileURLWithPath: "/x.plist"), origin: .user)
        #expect(ScheduleRule.rules(for: plist).isEmpty)
        plist.startInterval = 60
        plist.calendarIntervals = [["Hour": 1]]
        #expect(ScheduleRule.rules(for: plist) == [.interval(seconds: 60), .calendar([["Hour": 1]])])
    }
}

@Suite struct RunHistoryTests {
    @Test func parsesRealSpawnHistory() throws {
        let url = try #require(Bundle.module.url(forResource: "unifiedlog-spawns", withExtension: "ndjson", subdirectory: "Fixtures"))
        let entries = UnifiedLog.parse(ndjson: try String(contentsOf: url, encoding: .utf8))
        let history = UnifiedLog.parseRunHistory(entries, domain: "gui/501")
        let updater = try #require(history["com.google.GoogleUpdater.wake"])
        #expect(updater.count >= 20)
        #expect(updater.allSatisfy { $0.kind == .started(reason: "interval") })
        #expect(updater.lastStart == updater.last?.date)
    }

    @Test func parsesExits() {
        let date = Date(timeIntervalSince1970: 0)
        let entries = [
            LogEntry(id: 0, date: date, subsystem: "gui/501/x [5]", message: "Successfully spawned x[5] because calendar"),
            LogEntry(id: 1, date: date, subsystem: "gui/501/x [5]", message: "exited due to exit(78), ran for 12ms"),
            LogEntry(id: 2, date: date, subsystem: "gui/501/y [6]", message: "exited due to SIGTERM | sent by launchctl[7], ran for 3ms"),
            LogEntry(id: 3, date: date, subsystem: "gui/501 [100020]", message: "service inactive: x"),
        ]
        let history = UnifiedLog.parseRunHistory(entries, domain: "gui/501")
        #expect(history["x"]?.map(\.kind) == [.started(reason: "calendar"), .exited(code: 78, description: "due to exit(78)")])
        #expect(history["x"]?.last?.isFailedExit == true)
        #expect(history["y"]?.first?.isFailedExit == false)
        #expect(history.count == 2)
    }

    @Test func predicateCoversEveryLabel() {
        let predicate = UnifiedLog.runHistoryPredicate(domain: "gui/501", labels: ["a", "b"])
        #expect(predicate.contains(#"subsystem BEGINSWITH "gui/501/a [" OR subsystem BEGINSWITH "gui/501/b [""#))
    }
}

@Suite struct BackgroundItemsTests {
    let items: [BackgroundItem]

    init() throws {
        items = BackgroundItems.parse(dump: try fixture("btm-dump"), uid: 501, home: "/Users/me")
    }

    @Test func parsesRealDump() throws {
        #expect(items.count == 13)
        let hub = try #require(items.first { $0.label == "com.hapi.hub" })
        #expect(hub.identifier == "8.com.hapi.hub")
        #expect(hub.url == "/Users/me/Library/LaunchAgents/com.hapi.hub.plist")
        #expect(hub.executablePath == "/Users/me/.local/bin/hapi")
        #expect(hub.isAllowed && hub.isEnabled && hub.isJob)
        #expect(hub.name == "hapi")
        #expect(hub.developerName == nil)

        let nginx = try #require(items.first { $0.label == "homebrew.mxcl.nginx" })
        #expect(!nginx.isAllowed)
    }

    @Test func resolvesParentApps() throws {
        let info = BackgroundItems.infoByLabel(items)
        #expect(info["org.pqrs.service.agent.Karabiner-Core-Service"]?.appName == "Karabiner-Elements Non-Privileged Agents v2")
        #expect(info["org.pqrs.service.agent.Karabiner-Core-Service"]?.developer == "Fumihiko Takayama")
        #expect(info["com.docker.helper"]?.developer == "Docker Inc")
        #expect(info["com.adobe.ccxprocess"]?.appName == "Adobe Creative Cloud")
        #expect(info["com.hapi.hub"]?.appName == nil)
        // App and developer records aren't jobs.
        #expect(info["com.docker.docker"] == nil)
    }

    @Test func otherUsersAndGarbageYieldNothing() throws {
        #expect(BackgroundItems.parse(dump: try fixture("btm-dump"), uid: 502).isEmpty)
        #expect(BackgroundItems.parse(dump: "sfltool: permission denied").isEmpty)
    }

    @Test func blockedJobExplainsItself() {
        var plist = PlistJob(url: URL(fileURLWithPath: "/Library/LaunchAgents/x.plist"), origin: .global)
        plist.label = "x"
        plist.runAtLoad = true
        let snapshot = DomainSnapshot(domain: "gui/501", services: [:], overrides: [:])
        let blocked = Inventory.build(snapshot: snapshot, plists: [plist], loginItems: ["x": LoginItemInfo(isAllowed: false, appName: "Example")])[0]
        #expect(blocked.issues == [.blockedInLoginItems(app: "Example")])
        let allowed = Inventory.build(snapshot: snapshot, plists: [plist], loginItems: ["x": LoginItemInfo(isAllowed: true)])[0]
        #expect(allowed.issues == [.shouldBeLoaded])
        #expect(ActionPolicy.actions(for: blocked) == [.disable])
        #expect(ActionPolicy.actions(for: allowed) == [.load, .disable])
    }
}

@Suite struct FailureWatcherTests {
    private func job(_ status: (pid: Int?, exit: LaunchdKit.ExitStatus)?, keepAlive: KeepAlive = .off, disabled: Bool = false) -> Job {
        var plist = PlistJob(url: URL(fileURLWithPath: "/Users/me/Library/LaunchAgents/x.plist"), origin: .user)
        plist.label = "x"
        plist.keepAlive = keepAlive
        let services = status.map { ["x": ServiceEntry(label: "x", pid: $0.pid, lastExit: $0.exit)] } ?? [:]
        return Inventory.build(
            snapshot: DomainSnapshot(domain: "gui/501", services: services, overrides: disabled ? ["x": .disabled] : [:]),
            plists: [plist]
        )[0]
    }

    let running: (pid: Int?, exit: LaunchdKit.ExitStatus) = (5, .none)
    let failed: (pid: Int?, exit: LaunchdKit.ExitStatus) = (nil, .code(1))

    @Test func notifiesOnceWhenAWatchedJobStartsFailing() {
        var watcher = FailureWatcher()
        let start = Date(timeIntervalSince1970: 0)
        #expect(watcher.events(previous: [job(running)], current: [job(failed)], watched: ["gui/501/x"], now: start)
            == [.init(label: "x", message: "Exited with 1.")])
        // A crash loop flips running ↔ failing every ~10 s; stay quiet within the cooldown.
        #expect(watcher.events(previous: [job(running)], current: [job(failed)], watched: ["gui/501/x"], now: start + 60).isEmpty)
        #expect(watcher.events(previous: [job(running)], current: [job(failed)], watched: ["gui/501/x"], now: start + 16 * 60).count == 1)
    }

    @Test func ignoresUnwatchedFirstSeenAndStillFailing() {
        var watcher = FailureWatcher()
        #expect(watcher.events(previous: [job(running)], current: [job(failed)], watched: [], now: .now).isEmpty)
        #expect(watcher.events(previous: [], current: [job(failed)], watched: ["gui/501/x"], now: .now).isEmpty)
        #expect(watcher.events(previous: [job(failed)], current: [job(failed)], watched: ["gui/501/x"], now: .now).isEmpty)
    }

    @Test func notifiesOnQuietKeepAliveStopAndUnexpectedUnload() {
        var watcher = FailureWatcher()
        let stopped = watcher.events(
            previous: [job(running, keepAlive: .always)], current: [job((nil, .code(0)), keepAlive: .always)],
            watched: ["gui/501/x"], now: Date(timeIntervalSince1970: 0)
        )
        #expect(stopped.first?.message.contains("KeepAlive") == true)

        var other = FailureWatcher()
        #expect(other.events(previous: [job(running)], current: [job(nil)], watched: ["gui/501/x"], now: .now).first?.message == "Was unloaded.")
        // Unloading a job you disabled is expected.
        var third = FailureWatcher()
        #expect(third.events(previous: [job(running)], current: [job(nil, disabled: true)], watched: ["gui/501/x"], now: .now).isEmpty)
    }
}
