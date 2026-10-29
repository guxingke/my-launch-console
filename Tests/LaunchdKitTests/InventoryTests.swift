import Foundation
import Testing
@testable import LaunchdKit

private func plist(_ label: String, origin: Origin = .user, fileName: String? = nil, _ configure: (inout PlistJob) -> Void = { _ in }) -> PlistJob {
    let dir = origin == .user ? "/Users/me/Library/LaunchAgents" : "/Library/LaunchAgents"
    var job = PlistJob(url: URL(fileURLWithPath: "\(dir)/\(fileName ?? label).plist"), origin: origin)
    job.label = label
    job.programArguments = ["/usr/local/bin/\(label)"]
    configure(&job)
    return job
}

private func snapshot(services: [ServiceEntry] = [], overrides: [String: Override] = [:]) -> DomainSnapshot {
    DomainSnapshot(
        domain: "gui/501",
        services: Dictionary(uniqueKeysWithValues: services.map { ($0.label, $0) }),
        overrides: overrides
    )
}

private func job(_ label: String, in jobs: [Job]) throws -> Job {
    try #require(jobs.first { $0.label == label })
}

@Suite struct InventoryTests {
    @Test func derivesStatusFromAllThreeSources() throws {
        let jobs = Inventory.build(
            snapshot: snapshot(
                services: [
                    ServiceEntry(label: "running", pid: 42, lastExit: .none),
                    ServiceEntry(label: "failing", pid: nil, lastExit: .code(1)),
                    ServiceEntry(label: "idle", pid: nil, lastExit: .code(0)),
                    ServiceEntry(label: "application.com.example.App.1.2", pid: 7, lastExit: .none),
                    ServiceEntry(label: "com.apple.thing", pid: nil, lastExit: .none),
                ],
                overrides: ["disabled": .disabled, "gone": .enabled]
            ),
            plists: [
                plist("running"), plist("failing"), plist("idle"),
                plist("unloaded"),
                plist("disabled"),
                plist("plist-disabled") { $0.disabledKey = true },
            ]
        )

        #expect(try job("running", in: jobs).status == .running)
        #expect(try job("failing", in: jobs).status == .failing)
        #expect(try job("idle", in: jobs).status == .idle)
        #expect(try job("unloaded", in: jobs).status == .notLoaded)
        #expect(try job("disabled", in: jobs).status == .disabled)
        #expect(try job("plist-disabled", in: jobs).status == .disabled)
        #expect(try job("gone", in: jobs).status == .staleOverride)

        #expect(try job("application.com.example.App.1.2", in: jobs).origin == .app)
        #expect(try job("com.apple.thing", in: jobs).origin == .apple)
        #expect(try job("running", in: jobs).origin == .user)
    }

    @Test func enableOverrideBeatsPlistDisabledKey() throws {
        let jobs = Inventory.build(
            snapshot: snapshot(overrides: ["x": .enabled]),
            plists: [plist("x") { $0.disabledKey = true }]
        )
        #expect(try job("x", in: jobs).status == .notLoaded)
    }

    @Test func flagsMismatches() throws {
        let jobs = Inventory.build(
            snapshot: snapshot(
                services: [
                    ServiceEntry(label: "failing", pid: nil, lastExit: .code(78)),
                    ServiceEntry(label: "still-loaded", pid: 3, lastExit: .none),
                ],
                overrides: ["still-loaded": .disabled, "gone": .disabled]
            ),
            plists: [
                plist("failing"),
                plist("still-loaded"),
                plist("should-run") { $0.runAtLoad = true },
                plist("login-window-only") { $0.runAtLoad = true; $0.sessionTypes = ["LoginWindow"] },
                plist("renamed", fileName: "old-name"),
                plist("dup", origin: .user),
                plist("dup", origin: .global),
            ]
        )

        #expect(try job("failing", in: jobs).issues == [.lastExitFailed(.code(78))])
        #expect(try job("still-loaded", in: jobs).issues == [.loadedButDisabled])
        #expect(try job("should-run", in: jobs).issues == [.shouldBeLoaded])
        #expect(try job("login-window-only", in: jobs).issues.isEmpty)
        #expect(try job("renamed", in: jobs).issues == [.labelDiffersFromFilename(fileName: "old-name.plist")])
        #expect(try job("dup", in: jobs).issues == [.duplicateDefinition(path: "/Library/LaunchAgents/dup.plist")])
        #expect(try job("dup", in: jobs).origin == .user)
        #expect(try job("gone", in: jobs).issues == [.staleOverride(.disabled)])
    }

    @Test func buildsFromRealDomainWithoutPlists() throws {
        let snap = try #require(DomainSnapshot(parsing: fixture("domain-gui")))
        let jobs = Inventory.build(snapshot: snap, plists: [])
        #expect(jobs.count == Set(snap.services.keys).union(snap.overrides.keys).count)
        #expect(try job("homebrew.mxcl.sing-box", in: jobs).status == .failing)
    }
}

@Suite struct DiagnosticsTests {
    @Test func detectsCrashLoop() throws {
        let detail = try #require(ServiceDetail(parsing: fixture("service-crashloop")))
        let job = Inventory.build(
            snapshot: snapshot(services: [ServiceEntry(label: "homebrew.mxcl.sing-box", pid: nil, lastExit: .code(1))]),
            plists: []
        )[0]
        let issues = Diagnostics.detailIssues(for: job, detail: detail, fileExists: { _ in true })
        #expect(issues == [.crashLoop(runs: 21956)])
    }

    @Test func detectsDeletedPlistAndConfigDrift() throws {
        let detail = try #require(ServiceDetail(parsing: fixture("service-running-agent")))
        let edited = plist("com.hapi.hub") { $0.programArguments = ["/Users/gxk/.local/bin/hapi", "hub", "--verbose"] }
        let job = Inventory.build(
            snapshot: snapshot(services: [ServiceEntry(label: "com.hapi.hub", pid: 967, lastExit: .none)]),
            plists: [edited]
        )[0]

        let issues = Diagnostics.detailIssues(for: job, detail: detail, fileExists: { _ in false })
        #expect(issues == [
            .loadedPlistMissing(path: "/Users/gxk/Library/LaunchAgents/com.hapi.hub.plist"),
            .loadedConfigDiffers,
        ])
    }

    @Test func matchingConfigIsQuiet() throws {
        let detail = try #require(ServiceDetail(parsing: fixture("service-running-agent")))
        let same = plist("com.hapi.hub") { $0.programArguments = ["/Users/gxk/.local/bin/hapi", "hub"] }
        let job = Inventory.build(snapshot: snapshot(), plists: [same])[0]
        #expect(Diagnostics.detailIssues(for: job, detail: detail, fileExists: { _ in true }).isEmpty)
    }
}

@Suite struct PlistJobTests {
    @Test func loadsAndCachesFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dict: [String: Any] = [
            "Label": "com.example.job",
            "ProgramArguments": ["/bin/sh", "-c", "true"],
            "KeepAlive": ["SuccessfulExit": false],
            "StartCalendarInterval": ["Hour": 3, "Minute": 0],
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        try data.write(to: dir.appending(path: "com.example.job.plist"))
        try Data("not a plist".utf8).write(to: dir.appending(path: "broken.plist"))
        try Data().write(to: dir.appending(path: "ignored.txt"))
        try FileManager.default.createSymbolicLink(atPath: dir.appending(path: "dangling.plist").path, withDestinationPath: "/nonexistent/x.plist")

        let catalog = PlistCatalog(directories: [.init(url: dir, origin: .user)])
        let jobs = catalog.scan()
        #expect(jobs.count == 3)
        let dangling = try #require(jobs.first { $0.effectiveLabel == "dangling" })
        #expect(dangling.error?.hasPrefix("Broken symlink to /nonexistent/x.plist") == true)

        let good = try #require(jobs.first { $0.label == "com.example.job" })
        #expect(good.commandLine == ["/bin/sh", "-c", "true"])
        #expect(good.keepAlive == .conditional(["SuccessfulExit"]))
        #expect(good.calendarIntervals == [["Hour": 3, "Minute": 0]])
        #expect(good.sessionTypes == ["Aqua"])
        #expect(good.xml?.contains("<key>Label</key>") == true)

        let broken = try #require(jobs.first { $0.effectiveLabel == "broken" })
        #expect(broken.error != nil)

        #expect(catalog.scan() == jobs)
    }
}
