import Foundation
import Testing
@testable import LaunchdKit

private func makeJob(
    _ label: String = "com.example.job",
    origin: Origin = .user,
    plist hasPlist: Bool = true,
    service: ServiceEntry? = nil,
    override: Override? = nil,
    configure: (inout PlistJob) -> Void = { _ in }
) -> Job {
    var plists: [PlistJob] = []
    if hasPlist {
        var plist = PlistJob(url: URL(fileURLWithPath: "/Users/me/Library/LaunchAgents/\(label).plist"), origin: origin)
        plist.label = label
        plist.programArguments = ["/bin/sleep", "600"]
        configure(&plist)
        plists.append(plist)
    }
    let snapshot = DomainSnapshot(
        domain: "gui/501",
        services: service.map { [label: $0] } ?? [:],
        overrides: override.map { [label: $0] } ?? [:]
    )
    return Inventory.build(snapshot: snapshot, plists: plists)[0]
}

@Suite struct ExitStatusTests {
    @Test func negativeCodesAreSignals() throws {
        let snapshot = try #require(DomainSnapshot(parsing: """
        gui/501 = {
        \tservices = {
        \t\t       0    -15 \tterm
        \t\t       0     -9 \tkill
        \t}
        }
        """))
        #expect(snapshot.services["term"]?.lastExit == .signal(15))
        #expect(snapshot.services["kill"]?.lastExit == .signal(9))
        #expect(ExitStatus.signal(15).isFailure == false)
        #expect(ExitStatus.signal(9).isFailure)
        #expect(ExitStatus.signal(15).description == "SIGTERM")
    }

    @Test func detailFallsBackToTerminatingSignal() throws {
        let detail = try #require(ServiceDetail(parsing: """
        gui/501/x = {
        \tstate = not running
        \tlast terminating signal = Terminated: 15
        }
        """))
        #expect(detail.lastExit == .signal(15))
    }

    @Test func stoppedJobIsIdleNotFailing() {
        let job = makeJob(service: ServiceEntry(label: "com.example.job", pid: nil, lastExit: .signal(15)))
        #expect(job.status == .idle)
        #expect(job.issues.isEmpty)
    }
}

@Suite struct ActionPolicyTests {
    @Test func runningJob() {
        let job = makeJob(service: ServiceEntry(label: "com.example.job", pid: 42, lastExit: .none))
        #expect(ActionPolicy.actions(for: job) == [.restart, .stop, .unload, .disable])
    }

    @Test func loadedIdleJob() {
        let job = makeJob(service: ServiceEntry(label: "com.example.job", pid: nil, lastExit: .code(0)))
        #expect(ActionPolicy.actions(for: job) == [.start, .unload, .disable])
    }

    @Test func notLoadedJob() {
        #expect(ActionPolicy.actions(for: makeJob()) == [.load, .disable])
    }

    @Test func disabledJobMustBeEnabledBeforeLoading() {
        #expect(ActionPolicy.actions(for: makeJob(override: .disabled)) == [.enable])
    }

    @Test func brokenPlistCantBeLoaded() {
        let job = makeJob { $0.error = "Broken symlink" }
        #expect(ActionPolicy.actions(for: job) == [.disable])
    }

    @Test func loadedJobWithoutPlistCantBeUnloaded() {
        let job = makeJob("com.docker.helper", plist: false, service: ServiceEntry(label: "com.docker.helper", pid: 5, lastExit: .none))
        #expect(job.origin == .app)
        #expect(ActionPolicy.actions(for: job) == [.restart, .stop, .disable])
    }

    @Test func readOnlyJobs() {
        let apple = makeJob("com.apple.thing", origin: .apple)
        let app = makeJob("application.com.example.App.1.2", plist: false, service: ServiceEntry(label: "application.com.example.App.1.2", pid: 9, lastExit: .none))
        let leftover = makeJob(plist: false, override: .enabled)
        for job in [apple, app, leftover] {
            #expect(ActionPolicy.readOnlyReason(for: job) != nil)
            #expect(ActionPolicy.actions(for: job).isEmpty)
        }
    }

    @Test func stopWarnsAboutKeepAlive() {
        let job = makeJob(service: ServiceEntry(label: "com.example.job", pid: 1, lastExit: .none)) { $0.keepAlive = .always }
        #expect(ActionPolicy.consequence(of: .stop, for: job).contains("KeepAlive"))
    }
}

@Suite struct CommandTests {
    let launchctl = Launchctl(domain: "gui/501")

    @Test func buildsModernVerbs() throws {
        let job = makeJob()
        let expected: [JobAction: String] = [
            .start: "launchctl kickstart gui/501/com.example.job",
            .restart: "launchctl kickstart -k gui/501/com.example.job",
            .stop: "launchctl kill SIGTERM gui/501/com.example.job",
            .load: "launchctl bootstrap gui/501 /Users/me/Library/LaunchAgents/com.example.job.plist",
            .unload: "launchctl bootout gui/501/com.example.job",
            .enable: "launchctl enable gui/501/com.example.job",
            .disable: "launchctl disable gui/501/com.example.job",
        ]
        for action in JobAction.allCases {
            #expect(try #require(launchctl.command(for: action, on: job)).shellString == expected[action])
        }
    }

    @Test func quotesPathsWithSpaces() {
        #expect(LaunchctlCommand.shellQuote("/Library/Application Support/x.plist") == "'/Library/Application Support/x.plist'")
        #expect(LaunchctlCommand.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func hintsExplainBootstrapError5() {
        let loaded = makeJob(service: ServiceEntry(label: "com.example.job", pid: 1, lastExit: .none))
        #expect(Launchctl.hint(for: .load, status: 5, job: loaded) == "It's already loaded.")
        #expect(Launchctl.hint(for: .load, status: 5, job: makeJob(override: .disabled))?.hasPrefix("It's disabled") == true)
        #expect(Launchctl.hint(for: .load, status: 5, job: makeJob()) == "The plist no longer exists.")
        #expect(Launchctl.hint(for: .stop, status: 3, job: loaded) == "It isn't running.")
    }
}

/// Exercises real launchctl against a throwaway `/bin/sleep` job loaded from a temp directory.
/// Off by default because it changes launchd state: `LAUNCHD_INTEGRATION=1 swift test`.
/// Leaves one `enabled` entry for its label in the user's override database (launchctl
/// can't remove those without root).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LAUNCHD_INTEGRATION"] == "1"), .serialized)
struct LaunchctlIntegrationTests {
    static let label = "local.prototype.launchconsole.integration"

    @Test func fullLifecycle() async throws {
        let launchctl = Launchctl.currentUserGUI()
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(Self.label).plist")
        let dict: [String: Any] = ["Label": Self.label, "ProgramArguments": ["/bin/sleep", "600"]]
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
        defer {
            _ = try? Process.run(URL(fileURLWithPath: Launchctl.executable), arguments: ["bootout", launchctl.target(Self.label)])
            try? FileManager.default.removeItem(at: dir)
        }

        func current() async throws -> Job {
            let snapshot = try await launchctl.printDomain()
            let plist = PlistJob.load(url: url, origin: .user)
            return try #require(Inventory.build(snapshot: snapshot, plists: [plist]).first { $0.label == Self.label })
        }
        func perform(_ action: JobAction) async throws {
            let job = try await current()
            #expect(ActionPolicy.actions(for: job).contains(action), "\(action) not offered in state \(job.status)")
            try await launchctl.run(try #require(launchctl.command(for: action, on: job)), job: job)
            try await Task.sleep(for: .milliseconds(300))
        }

        #expect(try await current().status == .notLoaded)
        try await perform(.load)
        #expect(try await current().status == .idle)
        try await perform(.start)
        let running = try await current()
        #expect(running.status == .running)
        try await perform(.restart)
        #expect(try await current().pid != running.pid)
        try await perform(.stop)
        #expect(try await current().status == .idle)

        // A second load fails with launchctl's generic error 5; the hint names the real cause.
        let loaded = try await current()
        let load = try #require(launchctl.command(for: .load, on: loaded))
        await #expect(throws: ActionFailure.self) { try await launchctl.run(load, job: loaded) }
        do {
            try await launchctl.run(load, job: loaded)
        } catch let failure as ActionFailure {
            #expect(failure.status == 5)
            #expect(failure.hint == "It's already loaded.")
            #expect(!failure.output.contains("re-running the command as root"))
        }

        try await perform(.disable)
        #expect(try await current().issues.contains(.loadedButDisabled))
        try await perform(.unload)
        #expect(try await current().status == .disabled)
        try await perform(.enable)
        #expect(try await current().status == .notLoaded)
    }
}
